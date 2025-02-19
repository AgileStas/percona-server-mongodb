"""Tools for splitting suites into parallelizable sub-suites."""
from __future__ import annotations

import os
from copy import deepcopy
from datetime import datetime
from itertools import chain
from typing import NamedTuple, Callable, Optional, List, Dict, Any

import inject
import requests
import structlog
import yaml
from evergreen import EvergreenApi

from buildscripts.task_generation.resmoke_proxy import ResmokeProxyService
from buildscripts.task_generation.suite_split_strategies import SplitStrategy, FallbackStrategy
from buildscripts.task_generation.timeout import TimeoutEstimate
from buildscripts.util import taskname
from buildscripts.util.taskname import remove_gen_suffix
from buildscripts.util.teststats import HistoricTaskData, TestRuntime, normalize_test_name

LOGGER = structlog.getLogger(__name__)

CLEAN_EVERY_N_HOOK = "CleanEveryN"
HEADER_TEMPLATE = """# DO NOT EDIT THIS FILE. All manual edits will be lost.
# This file was generated by {file} from
# {suite_file}.
"""

# pylint: disable=too-many-arguments


def update_suite_config(suite_config, roots=None, excludes=None):
    """
    Update suite config based on the roots and excludes passed in.

    :param suite_config: suite_config to update.
    :param roots: new roots to run, or None if roots should not be updated.
    :param excludes: excludes to add, or None if excludes should not be include.
    :return: updated suite_config
    """
    if roots:
        suite_config["selector"]["roots"] = roots

    if excludes:
        # This must be a misc file, if the exclude_files section exists, extend it, otherwise,
        # create it.
        if "exclude_files" in suite_config["selector"] and \
                suite_config["selector"]["exclude_files"]:
            suite_config["selector"]["exclude_files"] += excludes
        else:
            suite_config["selector"]["exclude_files"] = excludes
    else:
        # if excludes was not specified this must not a misc file, so don"t exclude anything.
        if "exclude_files" in suite_config["selector"]:
            del suite_config["selector"]["exclude_files"]

    return suite_config


class SubSuite(object):
    """A suite of tests that can be run by evergreen."""

    def __init__(
            self,
            index: int,
            suite_name: str,
            test_list: List[str],
            tests_with_runtime_info: int,
            max_test_runtime: float,
            historic_runtime: float,
            task_overhead: float,
    ) -> None:
        """
        Initialize the object.

        :param index: Sub-suite index.
        :param suite_name: Name of suite.
        :param test_list: List of tests to include in this sub-suite.
        :param tests_with_runtime_info: Number of tests that that historic runtime info.
        :param max_test_runtime: Runtime of the longest running test.
        :param historic_runtime: Sum of the average runtime of all tests.
        :param task_overhead: Runtime overhead to expect from task level hooks.
        """
        self.index = index
        self.suite_name = suite_name
        self.test_list = test_list
        self.tests_with_runtime_info = tests_with_runtime_info
        self.max_test_runtime = max_test_runtime
        self.historic_runtime = historic_runtime
        self.task_overhead = task_overhead

    @classmethod
    def from_test_list(cls, index: int, suite_name: str, test_list: List[str],
                       task_overhead: Optional[float],
                       runtime_list: Optional[List[TestRuntime]] = None) -> SubSuite:
        """
        Create a sub-suite from the given test list.

        :param index: Index of sub-suite being created.
        :param suite_name: Name of suite.
        :param test_list: List of tests to include.
        :param task_overhead: Runtime overhead to expect from task level hooks.
        :param runtime_list: List of historic runtimes for tests in test_list.
        :return: Sub-suite for the given tests.
        """
        runtime_count = 0
        total_runtime = 0.0
        max_runtime = 0.0
        if runtime_list:
            runtime_map = {test.test_name: test.runtime for test in runtime_list}
            for test in test_list:
                if test in runtime_map:
                    runtime_count += 1
                    total_runtime += runtime_map[test]
                    max_runtime = max(max_runtime, runtime_map[test])

        return cls(index, suite_name, test_list, runtime_count, max_runtime, total_runtime,
                   task_overhead or 0.0)

    def should_overwrite_timeout(self) -> bool:
        """
        Whether the timeout for this suite should be overwritten.

        We should only overwrite the timeout if we have runtime info for all tests.
        """
        return len(self) == self.tests_with_runtime_info

    def get_timeout_estimate(self) -> TimeoutEstimate:
        """Get the estimated runtime of this task to for timeouts."""
        if self.should_overwrite_timeout():
            return TimeoutEstimate(max_test_runtime=self.max_test_runtime,
                                   expected_task_runtime=self.historic_runtime + self.task_overhead)
        return TimeoutEstimate.no_timeouts()

    def get_runtime(self):
        """Get the current average runtime of all the tests currently in this suite."""
        return self.historic_runtime

    def get_test_count(self) -> int:
        """Get the number of tests currently in this suite."""
        return len(self)

    def __len__(self) -> int:
        return len(self.test_list)

    def name(self, total_suites: int, suite_name: Optional[str] = None) -> str:
        """Get the name of this suite."""
        if suite_name is None:
            suite_name = self.suite_name
        return taskname.name_generated_task(suite_name, self.index, total_suites)

    def generate_resmoke_config(self, source_config: Dict) -> str:
        """
        Generate the contents of resmoke config for this suite.

        :param source_config: Resmoke config to base generate config on.
        :return: Resmoke config to run this suite.
        """
        suite_config = update_suite_config(deepcopy(source_config), roots=self.test_list)
        contents = HEADER_TEMPLATE.format(file=__file__, suite_file=self.suite_name)
        contents += yaml.safe_dump(suite_config, default_flow_style=False)
        return contents


class GeneratedSuite(NamedTuple):
    """
    Collection of sub-suites generated from the a parent suite.

    sub_suites: List of sub-suites comprising whole suite.
    build_variant: Name of build variant suite will run on.
    task_name: Name of task generating suite.
    suite_name: Name of suite.
    filename: File name containing suite config.
    include_build_variant_in_name: Include the build variant as part of display task names.
    """

    sub_suites: List[SubSuite]
    build_variant: str
    task_name: str
    suite_name: str
    filename: str
    include_build_variant_in_name: bool = False

    def display_task_name(self) -> str:
        """Get the display name to use for this task."""
        base_name = remove_gen_suffix(self.task_name)
        if self.include_build_variant_in_name:
            return f"{base_name}_{self.build_variant}"
        return base_name

    def get_test_list(self) -> List[str]:
        """Get the list of tests that will be run by this suite."""
        return list(chain.from_iterable(sub_suite.test_list for sub_suite in self.sub_suites))

    def __len__(self) -> int:
        """Get the number of sub-suites."""
        return len(self.sub_suites)


class SuiteSplitParameters(NamedTuple):
    """
    Parameters for splitting resmoke suites.

    build_variant: Build variant generated for.
    task_name: Name of task being split.
    suite_name: Name of suite being split.
    filename: Filename of suite configuration.
    is_asan: Whether the build variant being generated on is ASAN.
    test_file_filter: Optional filter describing which tests should be included.
    """

    build_variant: str
    task_name: str
    suite_name: str
    filename: str
    is_asan: bool = False
    test_file_filter: Optional[Callable[[str], bool]] = None


class SuiteSplitConfig(NamedTuple):
    """
    Global configuration for generating suites.

    evg_project: Evergreen project.
    target_resmoke_time: Target runtime for generated sub-suites.
    max_sub_suites: Max number of sub-suites to generate.
    max_tests_per_suite: Max number of tests to put in a single sub-suite.
    start_date: Start date to query for test history.
    end_date: End date to query for test history.
    default_to_fallback: Use the fallback method for splitting tasks rather than dynamic splitting.
    include_build_variant_in_name: Include the build variant as part of display task names.
    """

    evg_project: str
    target_resmoke_time: int
    max_sub_suites: int
    max_tests_per_suite: int
    start_date: datetime
    end_date: datetime
    default_to_fallback: bool = False
    include_build_variant_in_name: bool = False


class SuiteSplitService:
    """A service for splitting resmoke suites into sub-suites that can be run in parallel."""

    @inject.autoparams()
    def __init__(
            self,
            evg_api: EvergreenApi,
            resmoke_proxy: ResmokeProxyService,
            config: SuiteSplitConfig,
            split_strategy: SplitStrategy,
            fallback_strategy: FallbackStrategy,
    ) -> None:
        """
        Initialize the suite split service.

        :param evg_api: Evergreen API client.
        :param resmoke_proxy: Resmoke Proxy service.
        :param config: Configuration options of how to split suites.
        """
        self.evg_api = evg_api
        self.resmoke_proxy = resmoke_proxy
        self.config = config
        self.split_strategy = split_strategy
        self.fallback_strategy = fallback_strategy

    def split_suite(self, params: SuiteSplitParameters) -> GeneratedSuite:
        """
        Split the given resmoke suite into multiple sub-suites.

        :param params: Description of suite to split.
        :return: List of sub-suites from the given suite.
        """
        if self.config.default_to_fallback:
            return self.calculate_fallback_suites(params)

        try:
            evg_stats = HistoricTaskData.from_evg(self.evg_api, self.config.evg_project,
                                                  self.config.start_date, self.config.end_date,
                                                  params.task_name, params.build_variant)
            if not evg_stats:
                LOGGER.debug("No test history, using fallback suites")
                # This is probably a new suite, since there is no test history, just use the
                # fallback values.
                return self.calculate_fallback_suites(params)
            return self.calculate_suites_from_evg_stats(evg_stats, params)
        except requests.HTTPError as err:
            if err.response.status_code == requests.codes.SERVICE_UNAVAILABLE:
                # Evergreen may return a 503 when the service is degraded.
                # We fall back to splitting the tests into a fixed number of suites.
                LOGGER.warning("Received 503 from Evergreen, "
                               "dividing the tests evenly among suites")
                return self.calculate_fallback_suites(params)
            else:
                raise

    def calculate_fallback_suites(self, params: SuiteSplitParameters) -> GeneratedSuite:
        """Divide tests into a fixed number of suites."""
        LOGGER.debug("Splitting tasks based on fallback", max_sub_suites=self.config.max_sub_suites)
        test_list = self.resmoke_proxy.list_tests(params.suite_name)
        if params.test_file_filter:
            test_list = [test for test in test_list if params.test_file_filter(test)]

        test_lists = self.fallback_strategy(test_list, self.config.max_sub_suites)
        return self.test_lists_to_suite(test_lists, params, [])

    def calculate_suites_from_evg_stats(self, test_stats: HistoricTaskData,
                                        params: SuiteSplitParameters) -> GeneratedSuite:
        """
        Divide tests into suites that can be run in less than the specified execution time.

        :param test_stats: Historical test results for task being split.
        :param params: Description of how to split the suite.
        :return: List of sub suites calculated.
        """
        execution_time_secs = self.config.target_resmoke_time * 60
        tests_runtimes = self.filter_tests(test_stats.get_tests_runtimes(), params)
        if not tests_runtimes:
            LOGGER.debug("No test runtimes after filter, using fallback")
            return self.calculate_fallback_suites(params)

        test_lists = self.split_strategy(tests_runtimes, execution_time_secs,
                                         self.config.max_sub_suites,
                                         self.config.max_tests_per_suite,
                                         LOGGER.bind(task=params.task_name))

        return self.test_lists_to_suite(test_lists, params, tests_runtimes, test_stats)

    def test_lists_to_suite(self, test_lists: List[List[str]], params: SuiteSplitParameters,
                            tests_runtimes: List[TestRuntime],
                            test_stats: Optional[HistoricTaskData] = None) -> GeneratedSuite:
        """
        Create sub-suites for the given test lists.

        :param test_lists: List of tests lists to create suites for.
        :param params: Parameters for suite creation.
        :param tests_runtimes: Historic runtimes of tests.
        :param test_stats: Other historic task data.
        :return: Generated suite for the sub-suites specified.
        """
        suites = [
            SubSuite.from_test_list(
                index,
                params.suite_name,
                test_list,
                self.get_task_hook_overhead(params.suite_name, params.is_asan, len(test_list),
                                            test_stats),
                tests_runtimes,
            ) for index, test_list in enumerate(test_lists)
        ]

        return GeneratedSuite(
            sub_suites=suites,
            build_variant=params.build_variant,
            task_name=params.task_name,
            suite_name=params.suite_name,
            filename=params.filename,
            include_build_variant_in_name=self.config.include_build_variant_in_name,
        )

    def filter_tests(self, tests_runtimes: List[TestRuntime],
                     params: SuiteSplitParameters) -> List[TestRuntime]:
        """
        Filter out tests that do not exist in the filesystem.

        :param tests_runtimes: List of tests with runtimes to filter.
        :param params: Suite split parameters.
        :return: Test list with unneeded tests filtered out.
        """
        if params.test_file_filter:
            tests_runtimes = [
                test for test in tests_runtimes if params.test_file_filter(test.test_name)
            ]
        all_tests = [
            normalize_test_name(test) for test in self.resmoke_proxy.list_tests(params.suite_name)
        ]
        return [
            info for info in tests_runtimes
            if os.path.exists(info.test_name) and info.test_name in all_tests
        ]

    def get_task_hook_overhead(self, suite_name: str, is_asan: bool, test_count: int,
                               historic_stats: Optional[HistoricTaskData]) -> float:
        """
        Add how much overhead task-level hooks each suite should account for.

        Certain test hooks need to be accounted for on the task level instead of the test level
        in order to calculate accurate timeouts. So we will add details about those hooks to
        each suite here.

        :param suite_name: Name of suite being generated.
        :param is_asan: Whether ASAN is being used.
        :param test_count: Number of tests in sub-suite.
        :param historic_stats: Historic runtime data of the suite.
        """
        # The CleanEveryN hook is run every 'N' tests. The runtime of the
        # hook will be associated with whichever test happens to be running, which could be
        # different every run. So we need to take its runtime into account at the task level.
        if historic_stats is None:
            return 0.0

        clean_every_n_cadence = self._get_clean_every_n_cadence(suite_name, is_asan)
        avg_clean_every_n_runtime = historic_stats.get_avg_hook_runtime(CLEAN_EVERY_N_HOOK)
        LOGGER.debug("task hook overhead", cadence=clean_every_n_cadence,
                     runtime=avg_clean_every_n_runtime, is_asan=is_asan)
        if avg_clean_every_n_runtime != 0:
            n_expected_runs = test_count / clean_every_n_cadence
            return n_expected_runs * avg_clean_every_n_runtime
        return 0.0

    def _get_clean_every_n_cadence(self, suite_name: str, is_asan: bool) -> int:
        """
        Get the N value for the CleanEveryN hook.

        :param suite_name: Name of suite being generated.
        :param is_asan: Whether ASAN is being used.
        :return: How frequently clean every end is run.
        """
        # Default to 1, which is the worst case meaning CleanEveryN would run for every test.
        clean_every_n_cadence = 1
        if is_asan:
            # ASAN runs hard-code N to 1. See `resmokelib/testing/hooks/cleanup.py`.
            return clean_every_n_cadence

        clean_every_n_config = self._get_hook_config(suite_name, CLEAN_EVERY_N_HOOK)
        if clean_every_n_config:
            clean_every_n_cadence = clean_every_n_config.get("n", 1)

        return clean_every_n_cadence

    def _get_hook_config(self, suite_name: str, hook_name: str) -> Optional[Dict[str, Any]]:
        """
        Get the configuration for the given hook.

        :param hook_name: Name of hook to query.
        :return: Configuration for hook, if it exists.
        """
        hooks_config = self.resmoke_proxy.read_suite_config(suite_name).get("executor",
                                                                            {}).get("hooks")
        if hooks_config:
            for hook in hooks_config:
                if hook.get("class") == hook_name:
                    return hook

        return None
