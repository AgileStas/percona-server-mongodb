/*
 * Test that aggregation log lines include remoteOpWaitMillis: the amount of time the merger spent
 * waiting for results from shards.
 *
 * @tags: [uses_change_streams]
 */
(function() {

load("jstests/libs/log.js");  // For findMatchingLogLine, findMatchingLogLines.

const st = new ShardingTest({shards: 2, rs: {nodes: 1}});
st.stopBalancer();

const dbName = st.s.defaultDB;
const coll = st.s.getDB(dbName).getCollection('profile_remote_op_wait');
const shardDB = st.shard0.getDB(dbName);

coll.drop();
assert.commandWorked(st.s.adminCommand({enableSharding: dbName}));

// Shard the test collection and split it into two chunks: one that contains all {shard: 1}
// documents and one that contains all {shard: 2} documents.
st.shardColl(coll.getName(),
             {shard: 1} /* shard key */,
             {shard: 2} /* split at */,
             {shard: 2} /* move the chunk containing {shard: 2} to its own shard */,
             dbName,
             true);

assert.commandWorked(
    coll.insert(Array.from({length: 100}, (_, i) => ({_id: i, shard: (i % 2) + 1, x: i}))));

// We want a pipeline that:
// 1. Requires a mergerPart. Otherwise, the entire query might get passed through to one shard, and
//    we wouldn't spend time waiting for other nodes.
// 2. Is streaming. Otherwise, the merger would have to consume its entire input before returning
//    the first batch, meaning subsequent getMores wouldn't do any waiting.
// A merge-sort stage should satisfy both of these requirements.
const pipeline = [{$sort: {x: 1}}];
const pipelineComment = 'example_pipeline_should_have_remote_op_wait';

// Explain plans do not explicitly include the $mergeCursors stage, which does the merge sort. So to
// verify that the query will do a merge sort as we expect, we can check that:
// 1. The query targets both shards
// 2. The sort stage is pushed down
{
    const explain = coll.explain().aggregate(pipeline);
    assert(explain.shards, explain);
    assert.eq(2, Object.keys(explain.shards).length, explain);
    assert.eq(explain.splitPipeline.shardsPart, [{$sort: {sortKey: {x: 1}}}], explain);
    assert.eq(explain.splitPipeline.mergerPart, [], explain);
}

// Set the slow query logging threshold (slowMS) to -1 to ensure every query gets logged.
st.s.getDB('admin').setProfilingLevel(0, -1);

function getRemoteOpWait(logLine) {
    const pattern = /remoteOpWaitMillis:([0-9]+)/;
    const match = logLine.match(pattern);
    assert(match, `pattern ${pattern} did not match line: ${logLine}`);
    const millis = parseInt(match[1]);
    assert.gte(millis, 0, match);
    return millis;
}

function getDuration(logLine) {
    const pattern = / ([0-9]+)ms\s*$/;
    const match = logLine.match(pattern);
    assert(match, `pattern ${pattern} did not match line: ${logLine}`);
    const millis = parseInt(match[1]);
    assert.gte(millis, 0, match);
    return millis;
}

// Run the pipeline and check mongos for the log line.
const cursor = coll.aggregate(pipeline, {comment: pipelineComment, batchSize: 1});
{
    const mongosLog = assert.commandWorked(st.s.adminCommand({getLog: "global"}));
    const lines = mongosLog.log.filter(line => line.match(/command test.profile_remote_op_wait/));
    const line = findMatchingLogLine(lines, {comment: pipelineComment});
    assert(line, 'Failed to find a log line matching the comment');
    const remoteOpWait = getRemoteOpWait(line);
    const duration = getDuration(line);
    assert.lte(remoteOpWait, duration);
}

// Run a getMore and check again for the log line: .next() empties the current 1-document batch, and
// .hasNext() fetches a new batch.
cursor.next();
cursor.hasNext();
{
    const mongosLog = assert.commandWorked(st.s.adminCommand({getLog: "global"}));
    const lines = [...findMatchingLogLines(mongosLog.log, {comment: pipelineComment})];
    const line = lines.find(line => line.match(/command.{1,4}getMore/));
    assert(line, 'Failed to find a getMore log line matching the comment');
    const remoteOpWait = getRemoteOpWait(line);
    const duration = getDuration(line);
    assert.lte(remoteOpWait, duration);
}

// A changestream is a type of aggregation, so it reports remoteOpWait.
const watchComment = 'example_watch_should_have_remote_op_wait';
coll.watch([], {comment: watchComment}).hasNext();
{
    let mongosLog = assert.commandWorked(st.s.adminCommand({getLog: "global"}));
    const lines = mongosLog.log.filter(line => line.match(/command test.profile_remote_op_wait/));
    const line = findMatchingLogLine(lines, {comment: watchComment});
    assert(line, "Failed to find a log line matching the comment");
    const remoteOpWait = getRemoteOpWait(line);
    const duration = getDuration(line);
    assert.lte(remoteOpWait, duration);
}

// An equivalent .find() does not include remoteOpWaitMillis.
const findComment = 'example_find_should_not_have_remote_op_wait';
coll.find().sort({x: 1}).comment(findComment).next();
{
    const mongosLog = assert.commandWorked(st.s.adminCommand({getLog: "global"}));
    const lines = [...findMatchingLogLines(mongosLog.log, {comment: findComment})];
    const line = lines.find(line => line.match(/command.{1,4}find/));
    assert(line, "Failed to find a 'find' log line matching the comment");
    assert(!line.match(/remoteOpWait/), `Log line unexpectedly contained remoteOpWait: ${line}`);
}

// Other cursor-producing commands do not include remoteOpWaitMillis, such as listCollections.
const listCollectionsComment = 'example_listCollections_should_not_have_remote_op_wait';
coll.runCommand({listCollections: 1, comment: listCollectionsComment});
{
    const mongosLog = assert.commandWorked(st.s.adminCommand({getLog: "global"}));
    const lines = [...findMatchingLogLines(mongosLog.log, {comment: listCollectionsComment})];
    const line = lines.find(line => line.match(/command.{1,4}listCollections/));
    assert(line, "Failed to find a 'listCollections' log line matching the comment");
    assert(!line.match(/remoteOpWait/), `Log line unexpectedly contained remoteOpWait: ${line}`);
}

// A query that merges on a shard logs remoteOpWaitMillis on the shard.
const pipeline2 = [{$sort: {x: 1}}, {$group: {_id: "$y"}}];
const pipelineComment2 = 'example_pipeline2_should_have_remote_op_wait';
{
    const explain2 = coll.explain().aggregate(pipeline2, {allowDiskUse: true});
    assert.eq(explain2.mergeType, 'anyShard', explain2);
}
st.shard0.getDB('admin').setProfilingLevel(0, -1);
st.shard1.getDB('admin').setProfilingLevel(0, -1);
clearRawMongoProgramOutput();
coll.aggregate(pipeline2, {allowDiskUse: true, comment: pipelineComment2}).next();

// We terminate the processes to ensure that the next call to rawMongoProgramOutput()
// will return all of their output.
st.stop();
{
    const line = rawMongoProgramOutput().split('\n').find(line => line.match(/mergeCursors/) &&
                                                              line.match(/fromMongos: true/));
    assert(line, "Failed to find a log line mentioning 'mergeCursors' and 'fromMongos: true'");
    const remoteOpWait = getRemoteOpWait(line);
    const duration = getDuration(line);
    assert.lte(remoteOpWait, duration);
}
})();
