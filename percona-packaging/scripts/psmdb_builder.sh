#!/usr/bin/env bash

shell_quote_string() {
  echo "$1" | sed -e 's,\([^a-zA-Z0-9/_.=-]\),\\\1,g'
}

usage () {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given :
        --builddir=DIR      Absolute path to the dir where all actions will be performed
        --get_sources       Source will be downloaded from github
        --build_src_rpm     If it is set - src rpm will be built
        --build_src_deb  If it is set - source deb package will be built
        --build_rpm         If it is set - rpm will be built
        --build_deb         If it is set - deb will be built
        --build_tarball     If it is set - tarball will be built
        --install_deps      Install build dependencies(root privilages are required)
        --branch            Branch for build
        --repo              Repo for build
        --psm_ver           PSM_VER(mandatory)
        --psm_release       PSM_RELEASE(mandatory)
        --mongo_tools_tag   MONGO_TOOLS_TAG(mandatory)
        --special_targets   Special targets for tests
        --jenkins_mode      If it is set it means that this script is used on jenkins infrastructure
        --debug             build debug tarball
        --help) usage ;;
Example $0 --builddir=/tmp/PSMDB --get_sources=1 --build_src_rpm=1 --build_rpm=1
EOF
        exit 1
}

append_arg_to_args () {
  args="$args "$(shell_quote_string "$1")
}

parse_arguments() {
    pick_args=
    if test "$1" = PICK-ARGS-FROM-ARGV
    then
        pick_args=1
        shift
    fi

    for arg do
        val=$(echo "$arg" | sed -e 's;^--[^=]*=;;')
        case "$arg" in
            --builddir=*) WORKDIR="$val" ;;
            --build_src_rpm=*) SRPM="$val" ;;
            --build_src_deb=*) SDEB="$val" ;;
            --build_rpm=*) RPM="$val" ;;
            --build_deb=*) DEB="$val" ;;
            --get_sources=*) SOURCE="$val" ;;
            --build_tarball=*) TARBALL="$val" ;;
            --branch=*) BRANCH="$val" ;;
            --repo=*) REPO="$val" ;;
            --install_deps=*) INSTALL="$val" ;;
            --psm_ver=*) PSM_VER="$val" ;;
            --psm_release=*) PSM_RELEASE="$val" ;;
            --mongo_tools_tag=*) MONGO_TOOLS_TAG="$val" ;;
            --jenkins_mode=*) JENKINS_MODE="$val" ;;
            --debug=*) DEBUG="$val" ;;
            --special_targets=*) SPECIAL_TAR="$val" ;;
            --help) usage ;;
            *)
              if test -n "$pick_args"
              then
                  append_arg_to_args "$arg"
              fi
              ;;
        esac
    done
}

check_workdir(){
    if [ "x$WORKDIR" = "x$CURDIR" ]
    then
        echo >&2 "Current directory cannot be used for building!"
        exit 1
    else
        if ! test -d "$WORKDIR"
        then
            echo >&2 "$WORKDIR is not a directory."
            exit 1
        fi
    fi
    return
}

add_percona_yum_repo(){
    if [ ! -f /etc/yum.repos.d/percona-dev.repo ]
    then
      wget http://jenkins.percona.com/yum-repo/percona-dev.repo
      mv -f percona-dev.repo /etc/yum.repos.d/
    fi
    return
}

get_sources(){
    cd "${WORKDIR}"
    if [ "${SOURCE}" = 0 ]
    then
        echo "Sources will not be downloaded"
        return 0
    fi
    PRODUCT=percona-server-mongodb
    echo "PRODUCT=${PRODUCT}" > percona-server-mongodb-50.properties
    echo "PSM_BRANCH=${PSM_BRANCH}" >> percona-server-mongodb-50.properties
    echo "JEMALLOC_TAG=${JEMALLOC_TAG}" >> percona-server-mongodb-50.properties
    echo "BUILD_NUMBER=${BUILD_NUMBER}" >> percona-server-mongodb-50.properties
    echo "BUILD_ID=${BUILD_ID}" >> percona-server-mongodb-50.properties
    git clone "$REPO"
    retval=$?
    if [ $retval != 0 ]
    then
        echo "There were some issues during repo cloning from github. Please retry one more time"
        exit 1
    fi
    cd percona-server-mongodb
    if [ ! -z "$BRANCH" ]
    then
        git reset --hard
        git clean -xdf
        git checkout "$BRANCH"
    fi

    REVISION=$(git rev-parse --short HEAD)
    # create a proper version.json
    REVISION_LONG=$(git rev-parse HEAD)

    if [ -n "${JENKINS_MODE}" ]; then
        git remote add upstream https://github.com/mongodb/mongo.git
        git fetch upstream --tags

        PSM_VER=$(git describe --tags --abbrev=0 | sed 's/^psmdb-//' | sed 's/^r//' | awk -F '-' '{if ($2 ~ /^rc/) {print $0} else {print $1}}')
        MONGO_TOOLS_TAG="r${PSM_VER}"
    fi

    echo "{" > version.json
    echo "    \"version\": \"${PSM_VER}-${PSM_RELEASE}\"," >> version.json
    echo "    \"githash\": \"${REVISION_LONG}\"" >> version.json
    echo "}" >> version.json
    #

    PRODUCT_FULL=${PRODUCT}-${PSM_VER}-${PSM_RELEASE}
    echo "PRODUCT_FULL=${PRODUCT_FULL}" >> ${WORKDIR}/percona-server-mongodb-50.properties
    echo "VERSION=${PSM_VER}" >> ${WORKDIR}/percona-server-mongodb-50.properties
    echo "RELEASE=${PSM_RELEASE}" >> ${WORKDIR}/percona-server-mongodb-50.properties
    echo "MONGO_TOOLS_TAG=${MONGO_TOOLS_TAG}" >> ${WORKDIR}/percona-server-mongodb-50.properties

    echo "REVISION=${REVISION}" >> ${WORKDIR}/percona-server-mongodb-50.properties
    rm -fr debian rpm
    cp -a percona-packaging/manpages .
    cp -a percona-packaging/docs/* .
    #
    # submodules
    git submodule init
    git submodule update
    #
    git clone https://github.com/mongodb/mongo-tools.git
    cd mongo-tools
    git checkout $MONGO_TOOLS_TAG
    sed -i 's|VersionStr="$(go run release/release.go get-version)"|VersionStr="$PSMDB_TOOLS_REVISION"|' set_goenv.sh
    sed -i 's|GitCommit="$(git rev-parse HEAD)"|GitCommit="$PSMDB_TOOLS_COMMIT_HASH"|' set_goenv.sh
    echo "export PSMDB_TOOLS_COMMIT_HASH=\"$(git rev-parse HEAD)\"" > set_tools_revision.sh
    echo "export PSMDB_TOOLS_REVISION=\"${PSM_VER}-${PSM_RELEASE}\"" >> set_tools_revision.sh
    chmod +x set_tools_revision.sh
    cd ${WORKDIR}
    source percona-server-mongodb-50.properties
    #

    mv percona-server-mongodb ${PRODUCT}-${PSM_VER}-${PSM_RELEASE}
    cd ${PRODUCT}-${PSM_VER}-${PSM_RELEASE}
        git clone https://github.com/aws/aws-sdk-cpp.git
            cd aws-sdk-cpp
                git reset --hard
                git clean -xdf
                git checkout 1.8.56
                mkdir build
    cd ../../
    tar --owner=0 --group=0 --exclude=.* -czf ${PRODUCT}-${PSM_VER}-${PSM_RELEASE}.tar.gz ${PRODUCT}-${PSM_VER}-${PSM_RELEASE}
    echo "UPLOAD=UPLOAD/experimental/BUILDS/${PRODUCT}-5.0/${PRODUCT}-${PSM_VER}-${PSM_RELEASE}/${PSM_BRANCH}/${REVISION}/${BUILD_ID}" >> percona-server-mongodb-50.properties
    mkdir $WORKDIR/source_tarball
    mkdir $CURDIR/source_tarball
    cp ${PRODUCT}-${PSM_VER}-${PSM_RELEASE}.tar.gz $WORKDIR/source_tarball
    cp ${PRODUCT}-${PSM_VER}-${PSM_RELEASE}.tar.gz $CURDIR/source_tarball
    cd $CURDIR
    rm -rf percona-server-mongodb
    return
}

get_system(){
    if [ -f /etc/redhat-release ]; then
        GLIBC_VER_TMP="$(rpm glibc -qa --qf %{VERSION})"
        RHEL=$(rpm --eval %rhel)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
        OS_NAME="el$RHEL"
        OS="rpm"
    else
        GLIBC_VER_TMP="$(dpkg-query -W -f='${Version}' libc6 | awk -F'-' '{print $1}')"
        ARCH=$(uname -m)
        OS_NAME="$(lsb_release -sc)"
        OS="deb"
    fi
    export GLIBC_VER=".glibc${GLIBC_VER_TMP}"
    return
}

install_golang() {
    wget https://golang.org/dl/go1.15.7.linux-amd64.tar.gz -O /tmp/golang1.15.tar.gz
    tar --transform=s,go,go1.15, -zxf /tmp/golang1.15.tar.gz
    rm -rf /usr/local/go1.15 /usr/local/go1.11  /usr/local/go1.8 /usr/local/go1.9 /usr/local/go1.9.2 /usr/local/go
    mv go1.15 /usr/local/
    ln -s /usr/local/go1.15 /usr/local/go
}

install_gcc_8_centos(){
    if [ "${RHEL}" -lt 8 ]; then
        yum -y install  gcc-c++ devtoolset-8-gcc-c++ devtoolset-8-binutils cmake3 python38
        source /opt/rh/devtoolset-8/enable
    else
        yum -y install binutils gcc gcc-c++
    fi

}

install_gcc_8_deb(){
    if [ x"${DEBIAN}" = xxenial ]; then
        wget https://jenkins.percona.com/downloads/gcc8/gcc-8.3.0_Ubuntu-xenial-x64.tar.gz -O /tmp/gcc-8.3.0_Ubuntu-xenial-x64.tar.gz
        CUR_DIR=$PWD
        cd /tmp
        tar -zxf gcc-8.3.0_Ubuntu-xenial-x64.tar.gz
        rm -rf /usr/local/gcc-8.3.0
        mv gcc-8.3.0 /usr/local/
        cd $CUR_DIR
    fi
    if [ x"${DEBIAN}" = xfocal -o x"${DEBIAN}" = xbionic -o x"${DEBIAN}" = xdisco -o x"${DEBIAN}" = xbuster ]; then
        apt-get -y install gcc-8 g++-8
    fi
    if [ x"${DEBIAN}" = xbullseye ]; then
        apt-get -y install gcc-10 g++-10
    fi
    if [ x"${DEBIAN}" = xstretch ]; then
        wget https://jenkins.percona.com/downloads/gcc8/gcc-8.3.0_Debian-stretch-x64.tar.gz -O /tmp/gcc-8.3.0_Debian-stretch-x64.tar.gz
        tar -zxf /tmp/gcc-8.3.0_Debian-stretch-x64.tar.gz
        rm -rf /usr/local/gcc-8.3.0
        mv gcc-8.3.0 /usr/local/
    fi
}

set_compiler(){
    if [ "x$OS" = "xdeb" ]; then
        if [ x"${DEBIAN}" = xfocal -o x"${DEBIAN}" = xbionic -o x"${DEBIAN}" = xdisco -o x"${DEBIAN}" = xbuster ]; then
            export CC=/usr/bin/gcc-8
            export CXX=/usr/bin/g++-8
	elif [ x"${DEBIAN}" = xbullseye ]; then
            export CC=/usr/bin/gcc-10
            export CXX=/usr/bin/g++-10
        else
            export CC=/usr/local/gcc-8.3.0/bin/gcc-8.3
            export CXX=/usr/local/gcc-8.3.0/bin/g++-8.3
        fi
    else
        if [ "x${RHEL}" == "x8" ]; then
            export CC=/usr/bin/gcc
            export CXX=/usr/bin/g++
        else
            export CC=/opt/rh/devtoolset-8/root/usr/bin/gcc
            export CXX=/opt/rh/devtoolset-8/root/usr/bin/g++
        fi
    fi
}

fix_rules(){
    if [ x"${DEBIAN}" = xfocal -o x"${DEBIAN}" = xbionic -o x"${DEBIAN}" = xdisco -o x"${DEBIAN}" = xbuster ]; then
        sed -i 's|CC = gcc-5|CC = /usr/bin/gcc-8|' debian/rules
        sed -i 's|CXX = g++-5|CXX = /usr/bin/g++-8|' debian/rules
    elif [ x"${DEBIAN}" = xbullseye ]; then
        sed -i 's|CC = gcc-5|CC = /usr/bin/gcc-10|' debian/rules
        sed -i 's|CXX = g++-5|CXX = /usr/bin/g++-10|' debian/rules
    else
        sed -i 's|CC = gcc-5|CC = /usr/local/gcc-8.3.0/bin/gcc-8.3|' debian/rules
        sed -i 's|CXX = g++-5|CXX = /usr/local/gcc-8.3.0/bin/g++-8.3|' debian/rules
    fi
    sed -i 's:release:release --disable-warnings-as-errors :g' debian/rules
}

aws_sdk_build(){
    cd $WORKDIR
        git clone https://github.com/aws/aws-sdk-cpp.git
        cd aws-sdk-cpp
            git reset --hard
            git clean -xdf
            git checkout 1.8.56
            mkdir build
            cd build
            CMAKE_CMD="cmake"
            if [ -f /etc/redhat-release ]; then
                RHEL=$(rpm --eval %rhel)
                if [ x"$RHEL" = x6 ]; then
                    CMAKE_CMD="cmake3"
                fi
            fi
            set_compiler
            if [ -z "${CC}" -a -z "${CXX}" ]; then
                ${CMAKE_CMD} .. -DCMAKE_BUILD_TYPE=Release -DBUILD_ONLY="s3;transfer" -DBUILD_SHARED_LIBS=OFF -DMINIMIZE_SIZE=ON || exit $?
            else
                ${CMAKE_CMD} CC=${CC} CXX=${CXX} .. -DCMAKE_BUILD_TYPE=Release -DBUILD_ONLY="s3;transfer" -DBUILD_SHARED_LIBS=OFF -DMINIMIZE_SIZE=ON || exit $?
            fi
            make -j4 || exit $?
            make install
    cd ${WORKDIR}
}

install_deps() {
    if [ $INSTALL = 0 ]
    then
        echo "Dependencies will not be installed"
        return;
    fi
    if [ $( id -u ) -ne 0 ]
    then
        echo "It is not possible to instal dependencies. Please run as root"
        exit 1
    fi
    CURPLACE=$(pwd)
    if [ "x$OS" = "xrpm" ]; then
      yum -y update
      yum -y install wget
      add_percona_yum_repo
      wget http://jenkins.percona.com/yum-repo/percona-dev.repo
      mv -f percona-dev.repo /etc/yum.repos.d/
      yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
      percona-release enable tools testing
      yum clean all
      yum install -y patchelf
      RHEL=$(rpm --eval %rhel)
      if [ x"$RHEL" = x6 ]; then
        yum -y install epel-release
        yum -y install rpmbuild rpm-build libpcap-devel gcc make cmake gcc-c++ openssl-devel git
        yum -y install cyrus-sasl-devel snappy-devel zlib-devel bzip2-devel libpcap-devel
        yum -y install scons make rpm-build rpmbuild percona-devtoolset-gcc percona-devtoolset-binutils 
        yum -y install percona-devtoolset-gcc-c++ percona-devtoolset-libstdc++-devel percona-devtoolset-valgrind-devel
        yum -y install python27 python27-devel rpmlint libcurl-devel e2fsprogs-devel expat-devel lz4-devel git cmake3
        yum -y install openldap-devel krb5-devel xz-devel
        wget https://bootstrap.pypa.io/get-pip.py
        python2.7 get-pip.py
        rm -rf /usr/bin/python2
        ln -s /usr/bin/python2.7 /usr/bin/python2
      elif [ x"$RHEL" = x7 ]; then
        yum -y install epel-release
        yum -y install rpmbuild rpm-build libpcap-devel gcc make cmake gcc-c++ openssl-devel
        yum -y install cyrus-sasl-devel snappy-devel zlib-devel bzip2-devel scons rpmlint
        yum -y install rpm-build git libopcodes libcurl-devel rpmlint e2fsprogs-devel expat-devel lz4-devel which
        yum -y install openldap-devel krb5-devel xz-devel

        yum -y install centos-release-scl
        yum-config-manager --enable centos-sclo-rh-testing
        yum -y install rh-python38-python rh-python38-python-devel rh-python38-python-pip
        source /opt/rh/rh-python38/enable

        pip install --upgrade pip
        pip install --user setuptools --upgrade
        pip3.8 install --user typing pyyaml regex Cheetah3
        pip2.7 install --user typing pyyaml regex Cheetah Cheetah3
      else
        yum -y install bzip2-devel libpcap-devel snappy-devel gcc gcc-c++ rpm-build rpmlint
        yum -y install cmake cyrus-sasl-devel make openssl-devel zlib-devel libcurl-devel git
        yum -y install python2-scons python2-pip which
        yum -y install redhat-rpm-config python2-devel e2fsprogs-devel expat-devel lz4-devel
        yum -y install openldap-devel krb5-devel xz-devel
        yum -y install python38 python38-devel python38-pip
      fi
      if [ "x${RHEL}" == "x8" ]; then
        /usr/bin/pip3.8 install --user typing pyyaml regex Cheetah3
        /usr/bin/pip2.7 install --user typing pyyaml regex Cheetah
      fi
      wget https://curl.se/download/curl-7.66.0.tar.gz
      tar -xvzf curl-7.66.0.tar.gz
      cd curl-7.66.0
        ./configure
        make
        make install
      cd ../
#
      install_golang
      install_gcc_8_centos
      if [ -f /opt/rh/devtoolset-8/enable ]; then
        source /opt/rh/devtoolset-8/enable
        source /opt/rh/rh-python38/enable
      fi
      pip install --upgrade pip

    else
      apt-get -y update
      DEBIAN_FRONTEND=noninteractive apt-get -y install curl lsb-release wget apt-transport-https software-properties-common
      export DEBIAN=$(lsb_release -sc)
      export ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
      wget https://repo.percona.com/apt/pool/testing/p/percona-release/percona-release_1.0-27.generic_all.deb && dpkg -i percona-release_1.0-27.generic_all.deb
      if [ x"${DEBIAN}" = "xxenial" -o x"${DEBIAN}" = "xbionic" -o x"${DEBIAN}" = "xfocal" ]; then
        add-apt-repository -y ppa:deadsnakes/ppa
      elif [ x"${DEBIAN}" = "xstretch" -o x"${DEBIAN}" = "xbuster" ]; then
        wget https://people.debian.org/~paravoid/python-all/unofficial-python-all.asc
        mv unofficial-python-all.asc /etc/apt/trusted.gpg.d/
        echo "deb http://people.debian.org/~paravoid/python-all ${DEBIAN} main" | tee /etc/apt/sources.list.d/python-all.list
      fi
      percona-release enable tools testing
      apt-get update
      if [ x"${DEBIAN}" = "xbullseye" ]; then
        INSTALL_LIST="python3 python3-dev python3-pip"
      else
        INSTALL_LIST="python3.7 python3.7-dev dh-systemd"
      fi
      INSTALL_LIST="${INSTALL_LIST} git valgrind scons liblz4-dev devscripts debhelper debconf libpcap-dev libbz2-dev libsnappy-dev pkg-config zlib1g-dev libzlcore-dev libsasl2-dev gcc g++ cmake curl"
      INSTALL_LIST="${INSTALL_LIST} libssl-dev libcurl4-openssl-dev libldap2-dev libkrb5-dev liblzma-dev patchelf"
      if [ x"${DEBIAN}" != "xstretch" -a x"${DEBIAN}" != "xbullseye" ]; then
        INSTALL_LIST="${INSTALL_LIST} python3.7-distutils"
      fi
      until apt-get -y install dirmngr; do
        sleep 1
        echo "waiting"
      done
      until DEBIAN_FRONTEND=noninteractive apt-get -y install ${INSTALL_LIST}; do
        sleep 1
        echo "waiting"
      done
      apt-get -y install libext2fs-dev || apt-get -y install e2fslibs-dev
      install_golang
      install_gcc_8_deb
      wget https://bootstrap.pypa.io/get-pip.py
      if [ x"${DEBIAN}" = "xbullseye" ]; then
        update-alternatives --install /usr/bin/python python /usr/bin/python3.9 1
      else
        update-alternatives --install /usr/bin/python python /usr/bin/python3.7 1
        ln -sf /usr/bin/python3.7 /usr/bin/python3
      fi
      python get-pip.py
      easy_install pip
      pip install setuptools
    fi
    if [ x"${DEBIAN}" = "xstretch" ]; then
      LIBCURL_DEPS="libidn2-0-dev libldap2-dev libnghttp2-dev libnss3-dev libpsl-dev librtmp-dev libssh2-1-dev libssl1.0-dev"
      until DEBIAN_FRONTEND=noninteractive apt-get -y install ${LIBCURL_DEPS}; do
        sleep 1
        echo "waiting"
      done
      wget http://curl.haxx.se/download/curl-7.66.0.tar.gz
      tar -xvzf curl-7.66.0.tar.gz
        cd curl-7.66.0
        ./configure --enable-static --disable-shared --disable-dependency-tracking --disable-symbol-hiding --enable-versioned-symbols --enable-threaded-resolver --with-lber-lib=lber --with-gssapi=/usr --with-libssh2 --with-nghttp2 --with-zsh-functions-dir=/usr/share/zsh/vendor-completions --with-ca-path=/etc/ssl/certs --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt --with-ssl
        make
        make install
      cd ../
      CURL_LINKFLAGS=$(pkg-config libcurl --static --libs)
      export LDFLAGS="${LDFLAGS} ${CURL_LINKFLAGS}"
    fi
    aws_sdk_build
    return;
}

get_tar(){
    TARBALL=$1
    TARFILE=$(basename $(find $WORKDIR/$TARBALL -name 'percona-server-mongodb*.tar.gz' | sort | tail -n1))
    if [ -z $TARFILE ]
    then
        TARFILE=$(basename $(find $CURDIR/$TARBALL -name 'percona-server-mongodb*.tar.gz' | sort | tail -n1))
        if [ -z $TARFILE ]
        then
            echo "There is no $TARBALL for build"
            exit 1
        else
            cp $CURDIR/$TARBALL/$TARFILE $WORKDIR/$TARFILE
        fi
    else
        cp $WORKDIR/$TARBALL/$TARFILE $WORKDIR/$TARFILE
    fi
    return
}

get_deb_sources(){
    param=$1
    echo $param
    FILE=$(basename $(find $WORKDIR/source_deb -name "percona-server-mongodb*.$param" | sort | tail -n1))
    if [ -z $FILE ]
    then
        FILE=$(basename $(find $CURDIR/source_deb -name "percona-server-mongodb*.$param" | sort | tail -n1))
        if [ -z $FILE ]
        then
            echo "There is no sources for build"
            exit 1
        else
            cp $CURDIR/source_deb/$FILE $WORKDIR/
        fi
    else
        cp $WORKDIR/source_deb/$FILE $WORKDIR/
    fi
    return
}

build_srpm(){
    if [ $SRPM = 0 ]
    then
        echo "SRC RPM will not be created"
        return;
    fi
    if [ "x$OS" = "xdeb" ]
    then
        echo "It is not possible to build src rpm here"
        exit 1
    fi
    cd $WORKDIR
    get_tar "source_tarball"
    rm -fr rpmbuild
    ls | grep -v tar.gz | xargs rm -rf
    TARFILE=$(find . -name 'percona-server-mongodb*.tar.gz' | sort | tail -n1)
    SRC_DIR=${TARFILE%.tar.gz}
    #
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    tar vxzf ${WORKDIR}/${TARFILE} --wildcards '*/percona-packaging' --strip=1
    SPEC_TMPL=$(find percona-packaging/redhat -name 'percona-server-mongodb.spec.template' | sort | tail -n1)
    #
    cp -av percona-packaging/conf/* rpmbuild/SOURCES
    cp -av percona-packaging/redhat/mongod.* rpmbuild/SOURCES
    #
    sed -i 's:@@LOCATION@@:sysconfig:g' rpmbuild/SOURCES/*.service
    sed -i 's:@@LOCATION@@:sysconfig:g' rpmbuild/SOURCES/percona-server-mongodb-helper.sh
    sed -i 's:@@LOGDIR@@:mongo:g' rpmbuild/SOURCES/*.default
    sed -i 's:@@LOGDIR@@:mongo:g' rpmbuild/SOURCES/percona-server-mongodb-helper.sh
    #
    sed -e "s:@@SOURCE_TARBALL@@:$(basename ${TARFILE}):g" \
    -e "s:@@VERSION@@:${VERSION}:g" \
    -e "s:@@RELEASE@@:${RELEASE}:g" \
    -e "s:@@SRC_DIR@@:$SRC_DIR:g" \
    ${SPEC_TMPL} > rpmbuild/SPECS/$(basename ${SPEC_TMPL%.template})
    mv -fv ${TARFILE} ${WORKDIR}/rpmbuild/SOURCES
    if [ -f /opt/rh/devtoolset-8/enable ]; then
        source /opt/rh/devtoolset-8/enable
        source /opt/rh/rh-python38/enable
    fi
    rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" rpmbuild/SPECS/$(basename ${SPEC_TMPL%.template})
    mkdir -p ${WORKDIR}/srpm
    mkdir -p ${CURDIR}/srpm
    cp rpmbuild/SRPMS/*.src.rpm ${CURDIR}/srpm
    cp rpmbuild/SRPMS/*.src.rpm ${WORKDIR}/srpm
    return
}

build_rpm(){
    if [ $RPM = 0 ]
    then
        echo "RPM will not be created"
        return;
    fi
    if [ "x$OS" = "xdeb" ]
    then
        echo "It is not possible to build rpm here"
        exit 1
    fi
    SRC_RPM=$(basename $(find $WORKDIR/srpm -name 'percona-server-mongodb*.src.rpm' | sort | tail -n1))
    if [ -z $SRC_RPM ]
    then
        SRC_RPM=$(basename $(find $CURDIR/srpm -name 'percona-server-mongodb*.src.rpm' | sort | tail -n1))
        if [ -z $SRC_RPM ]
        then
            echo "There is no src rpm for build"
            echo "You can create it using key --build_src_rpm=1"
            exit 1
        else
            cp $CURDIR/srpm/$SRC_RPM $WORKDIR
        fi
    else
        cp $WORKDIR/srpm/$SRC_RPM $WORKDIR
    fi
    cd $WORKDIR
    rm -fr rpmbuild
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    cp $SRC_RPM rpmbuild/SRPMS/

    cd rpmbuild/SRPMS/
    rpm2cpio ${SRC_RPM} | cpio -id
    TARF=$(find . -name 'percona-server-mongodb*.tar.gz' | sort | tail -n1)
    tar vxzf ${TARF} --wildcards '*/etc' --strip=1
    if [ -f /opt/rh/devtoolset-8/enable ]; then
        source /opt/rh/devtoolset-8/enable
        source /opt/rh/rh-python38/enable
    fi
    RHEL=$(rpm --eval %rhel)
    ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
    if [ "x${RHEL}" == "x6" ]; then
        pip install --upgrade pip
        pip install --user -r etc/pip/dev-requirements.txt
        pip install --user -r etc/pip/evgtest-requirements.txt
    else
        pip3.8 install --upgrade pip
        pip3.8 install --user -r etc/pip/dev-requirements.txt
        pip3.8 install --user -r etc/pip/evgtest-requirements.txt
    fi
    #
    cd $WORKDIR
    if [ -f /opt/rh/devtoolset-8/enable ]; then
        source /opt/rh/devtoolset-8/enable
        source /opt/rh/rh-python38/enable
    fi

    echo "CC and CXX should be modified once correct compiller would be installed on Centos"
    if [ "x${RHEL}" == "x8" ]; then
        export CC=/usr/bin/gcc
        export CXX=/usr/bin/g++
    else
        export CC=/opt/rh/devtoolset-8/root/usr/bin/gcc
        export CXX=/opt/rh/devtoolset-8/root/usr/bin/g++
    fi
    #
    echo "RHEL=${RHEL}" >> percona-server-mongodb-50.properties
    echo "ARCH=${ARCH}" >> percona-server-mongodb-50.properties
    #
    file /usr/bin/scons
    #
    #if [ "x${RHEL}" == "x6" ]; then
        [[ ${PATH} == *"/usr/local/go/bin"* && -x /usr/local/go/bin/go ]] || export PATH=/usr/local/go/bin:${PATH}
        export GOROOT="/usr/local/go/"
        export GOPATH=$(pwd)/
        export PATH="/usr/local/go/bin:$PATH:$GOPATH"
        export GOBINPATH="/usr/local/go/bin"
    #fi
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .$OS_NAME" --rebuild rpmbuild/SRPMS/$SRC_RPM

    return_code=$?
    if [ $return_code != 0 ]; then
        exit $return_code
    fi
    mkdir -p ${WORKDIR}/rpm
    mkdir -p ${CURDIR}/rpm
    cp rpmbuild/RPMS/*/*.rpm ${WORKDIR}/rpm
    cp rpmbuild/RPMS/*/*.rpm ${CURDIR}/rpm
}

build_source_deb(){
    if [ $SDEB = 0 ]
    then
        echo "Source deb package will not be created"
        return;
    fi
    if [ "x$OS" = "xrpm" ]
    then
        echo "It is not possible to build source deb here"
        exit 1
    fi
    rm -rf percona-server-mongodb*
    get_tar "source_tarball"
    rm -f *.dsc *.orig.tar.gz *.debian.tar.gz *.changes
    #
    TARFILE=$(basename $(find . -name 'percona-server-mongodb*.tar.gz' | sort | tail -n1))
    DEBIAN=$(lsb_release -sc)
    ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
    tar zxf ${TARFILE}
    BUILDDIR=${TARFILE%.tar.gz}
    #
    rm -fr ${BUILDDIR}/debian
    cp -av ${BUILDDIR}/percona-packaging/debian ${BUILDDIR}
    cp -av ${BUILDDIR}/percona-packaging/conf/* ${BUILDDIR}/debian/
    #
    sed -i 's:@@LOCATION@@:default:g' ${BUILDDIR}/debian/*.service
    sed -i 's:@@LOCATION@@:default:g' ${BUILDDIR}/debian/percona-server-mongodb-helper.sh
    sed -i 's:@@LOGDIR@@:mongodb:g' ${BUILDDIR}/debian/mongod.default
    sed -i 's:@@LOGDIR@@:mongodb:g' ${BUILDDIR}/debian/percona-server-mongodb-helper.sh
    #
    mv ${BUILDDIR}/debian/mongod.default ${BUILDDIR}/debian/percona-server-mongodb-server.mongod.default
    mv ${BUILDDIR}/debian/mongod.service ${BUILDDIR}/debian/percona-server-mongodb-server.mongod.service
    #
    mv ${TARFILE} ${PRODUCT}_${VERSION}.orig.tar.gz
    cd ${BUILDDIR}
    pip install --upgrade pip
    pip install -r etc/pip/dev-requirements.txt
    pip install -r etc/pip/evgtest-requirements.txt

    set_compiler
    fix_rules

    dch -D unstable --force-distribution -v "${VERSION}-${RELEASE}" "Update to new Percona Server for MongoDB version ${VERSION}"
    dpkg-buildpackage -S
    cd ../
    mkdir -p $WORKDIR/source_deb
    mkdir -p $CURDIR/source_deb
    cp *.debian.tar.* $WORKDIR/source_deb
    cp *_source.changes $WORKDIR/source_deb
    cp *.dsc $WORKDIR/source_deb
    cp *.orig.tar.gz $WORKDIR/source_deb
    cp *.debian.tar.* $CURDIR/source_deb
    cp *_source.changes $CURDIR/source_deb
    cp *.dsc $CURDIR/source_deb
    cp *.orig.tar.gz $CURDIR/source_deb
}

build_deb(){
    if [ $DEB = 0 ]
    then
        echo "Deb package will not be created"
        return;
    fi
    if [ "x$OS" = "xrmp" ]
    then
        echo "It is not possible to build deb here"
        exit 1
    fi
    for file in 'dsc' 'orig.tar.gz' 'changes' 'debian.tar*'
    do
        get_deb_sources $file
    done
    cd $WORKDIR
    rm -fv *.deb
    #
    export DEBIAN=$(lsb_release -sc)
    export ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
    #
    echo "DEBIAN=${DEBIAN}" >> percona-server-mongodb-50.properties
    echo "ARCH=${ARCH}" >> percona-server-mongodb-50.properties

    #
    DSC=$(basename $(find . -name '*.dsc' | sort | tail -n1))
    #
    dpkg-source -x ${DSC}
    #
    cd ${PRODUCT}-${VERSION}
    pip install --upgrade pip
    pip install -r etc/pip/dev-requirements.txt
    pip install -r etc/pip/evgtest-requirements.txt
    #
    cp -av percona-packaging/debian/rules debian/
    set_compiler
    fix_rules
    if [ x"${DEBIAN}" = "xbullseye" ]; then
        sed -i 's:dh-systemd,::' debian/control
        sed -i 's:etc/:/etc/:g' debian/percona-server-mongodb-server.conffiles
    fi
    sed -i 's|VersionStr="$(go run release/release.go get-version)"|VersionStr="$PSMDB_TOOLS_REVISION"|' mongo-tools/set_goenv.sh
    sed -i 's|GitCommit="$(git rev-parse HEAD)"|GitCommit="$PSMDB_TOOLS_COMMIT_HASH"|' mongo-tools/set_goenv.sh
    sed -i 's|go build|go build -a -x|' mongo-tools/build.sh
    sed -i 's|exit $ec||' mongo-tools/build.sh
    . ./mongo-tools/set_tools_revision.sh
    dch -m -D "${DEBIAN}" --force-distribution -v "${VERSION}-${RELEASE}.${DEBIAN}" 'Update distribution'
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    if [ x"${DEBIAN}" = "xstretch" ]; then
      CURL_LINKFLAGS=$(pkg-config libcurl --static --libs)
      export LINKFLAGS="${LINKFLAGS} ${CURL_LINKFLAGS}"
    fi
    export GOROOT="/usr/local/go/"
    export GOPATH=$PWD/../
    export PATH="/usr/local/go/bin:$PATH:$GOPATH"
    export GOBINPATH="/usr/local/go/bin"
    dpkg-buildpackage -rfakeroot -us -uc -b
    mkdir -p $CURDIR/deb
    mkdir -p $WORKDIR/deb
    cp $WORKDIR/*.deb $WORKDIR/deb
    cp $WORKDIR/*.deb $CURDIR/deb
}

build_tarball(){
    if [ $TARBALL = 0 ]
    then
        echo "Binary tarball will not be created"
        return;
    fi
    get_tar "source_tarball"
    cd $WORKDIR
    TARFILE=$(basename $(find . -name 'percona-server-mongodb*.tar.gz' | sort | tail -n1))

    #
    export DEBIAN_VERSION="$(lsb_release -sc)"
    export DEBIAN="$(lsb_release -sc)"
    export PATH=/usr/local/go/bin:$PATH
    #
    #
    PSM_TARGETS="mongod mongos mongo mongobridge perconadecrypt $SPECIAL_TAR"
    PSM_REAL_TARGETS=() # transformed targets with 'install-' prefix
    for pp in $PSM_TARGETS
    do
        # using regex to find '=' characters in string
        # don't touch if it starts from '-' character or 'install-' string
        # also don't change parameter if it contains slash to preserve targets specifying full path to unittests or object files
        if [[ $pp =~ ^install-|^-|=|/ ]]; then
            # if - or = is found parameter is unchanged
            PSM_REAL_TARGETS+=( $pp )
        else
            # otherwise add 'install-' prefix required by hygienic build
            PSM_REAL_TARGETS+=( install-$pp )
        fi
    done

    TARBALL_SUFFIX=""
    if [ ${DEBUG} = 1 ]; then
    TARBALL_SUFFIX=".dbg"
    fi
    if [ -f /etc/debian_version ]; then
        set_compiler
    fi
    #
    if [ -f /etc/redhat-release ]; then
    #export OS_RELEASE="centos$(lsb_release -sr | awk -F'.' '{print $1}')"
        RHEL=$(rpm --eval %rhel)
        if [ -f /opt/rh/devtoolset-8/enable ]; then
            source /opt/rh/devtoolset-8/enable
            source /opt/rh/rh-python38/enable
        fi
        echo "CC and CXX should be modified once correct compiller would be installed on Centos"
        if [ "x${RHEL}" == "x8" ]; then
            export CC=/usr/bin/gcc
            export CXX=/usr/bin/g++
        else
            export CC=/opt/rh/devtoolset-8/root/usr/bin/gcc
            export CXX=/opt/rh/devtoolset-8/root/usr/bin/g++
        fi
    fi
    #
    ARCH=$(uname -m 2>/dev/null||true)
    TARFILE=$(basename $(find . -name 'percona-server-mongodb*.tar.gz' | sort | grep -v "tools" | tail -n1))
    PSMDIR=${TARFILE%.tar.gz}
    PSMDIR_ABS=${WORKDIR}/${PSMDIR}
    TOOLSDIR=${PSMDIR}/mongo-tools
    TOOLSDIR_ABS=${WORKDIR}/${TOOLSDIR}
    TOOLS_TAGS="ssl sasl"
    NJOBS=4

    tar xzf $TARFILE
    rm -f $TARFILE

    rm -fr /tmp/${PSMDIR}
    ln -fs ${PSMDIR_ABS} /tmp/${PSMDIR}
    cd /tmp
    #
    export CFLAGS="${CFLAGS:-} -fno-omit-frame-pointer"
    export CXXFLAGS="${CFLAGS}"
    if [ ${DEBUG} = 1 ]; then
    export CXXFLAGS="${CFLAGS} -Wno-error=deprecated-declarations"
    fi
    export INSTALLDIR=/usr/local
    export AWS_LIBS=/usr/local
    export PORTABLE=1
    export USE_SSE=1
    #

    # Finally build Percona Server for MongoDB with SCons
    cd ${PSMDIR_ABS}
    if [ "x${RHEL}" == "x8" ]; then
        pip3.6 install --upgrade pip
        pip3.6 install --user -r etc/pip/dev-requirements.txt
        pip3.6 install --user -r etc/pip/evgtest-requirements.txt
    else
        pip install --upgrade pip
        pip install --user -r etc/pip/dev-requirements.txt
        pip install --user -r etc/pip/evgtest-requirements.txt
    fi
    if [ -f /etc/redhat-release ]; then
        RHEL=$(rpm --eval %rhel)
        if [ $RHEL = 7 -o $RHEL = 8 ]; then
            if [ -d aws-sdk-cpp ]; then
                rm -rf aws-sdk-cpp
            fi
            export INSTALLDIR=$PWD/../install
            export INSTALLDIR_AWS=$PWD/../install_aws
            git clone https://github.com/aws/aws-sdk-cpp.git
            cd aws-sdk-cpp
            git reset --hard
            git clean -xdf
            git checkout 1.8.56
            mkdir build
            cd build
            set_compiler
            if [ -z "${CC}" -a -z "${CXX}" ]; then
                cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_ONLY="s3;transfer" -DBUILD_SHARED_LIBS=OFF -DMINIMIZE_SIZE=ON -DCMAKE_INSTALL_PREFIX="${INSTALLDIR_AWS}" || exit $?
            else
                cmake CC=${CC} CXX=${CXX} .. -DCMAKE_BUILD_TYPE=Release -DBUILD_ONLY="s3;transfer" -DBUILD_SHARED_LIBS=OFF -DMINIMIZE_SIZE=ON -DCMAKE_INSTALL_PREFIX="${INSTALLDIR_AWS}" || exit $?
            fi
            make -j4 || exit $?
            make install
            mkdir -p ${INSTALLDIR}/include/
            mkdir -p ${INSTALLDIR}/lib/
            mv ${INSTALLDIR_AWS}/include/* ${INSTALLDIR}/include/
            mv ${INSTALLDIR_AWS}/lib*/* ${INSTALLDIR}/lib/
            cd ../../

        fi
    fi
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    if [ x"${DEBIAN}" = "xstretch" ]; then
      CURL_LINKFLAGS=$(pkg-config libcurl --static --libs)
      export LINKFLAGS="${LINKFLAGS} ${CURL_LINKFLAGS}"
    fi
    if [ ${DEBUG} = 0 ]; then
        buildscripts/scons.py CC=${CC} CXX=${CXX} --disable-warnings-as-errors --release --ssl --opt=on -j$NJOBS --use-sasl-client --wiredtiger --audit --inmemory --hotbackup CPPPATH="${INSTALLDIR}/include ${AWS_LIBS}/include" LIBPATH="${INSTALLDIR}/lib ${AWS_LIBS}/lib ${AWS_LIBS}/lib64" LINKFLAGS="${LINKFLAGS}" ${PSM_REAL_TARGETS[@]} || exit $?
    else
        buildscripts/scons.py CC=${CC} CXX=${CXX} --disable-warnings-as-errors --audit --ssl --dbg=on -j$NJOBS --use-sasl-client \
        CPPPATH="${INSTALLDIR}/include ${AWS_LIBS}/include" LIBPATH="${INSTALLDIR}/lib ${AWS_LIBS}/lib ${AWS_LIBS}/lib64" LINKFLAGS="${LINKFLAGS}" --wiredtiger --inmemory --hotbackup ${PSM_REAL_TARGETS[@]} || exit $?
    fi
    #
    # scons install doesn't work - it installs the binaries not linked with fractal tree
    #scons --prefix=$PWD/$PSMDIR install
    #
    mkdir -p ${PSMDIR}/bin
    for target in ${PSM_TARGETS[@]}; do
        cp -f build/install/bin/$target ${PSMDIR}/bin
        if [ ${DEBUG} = 0 ]; then
            strip --strip-debug ${PSMDIR}/bin/${target}
        fi
    done
    #
    cd ${WORKDIR}
    #
    # Build mongo tools
    mkdir -p build_tools/src/github.com/mongodb/mongo-tools
    export GOROOT="/usr/local/go/"
    export GOPATH=$PWD/
    export PATH="/usr/local/go/bin:$PATH:$GOPATH"
    export GOBINPATH="/usr/local/go/bin"
    mkdir -p $GOPATH/src/github.com/mongodb
    cd $GOPATH/src/github.com/mongodb
    cp -r ${WORKDIR}/${TOOLSDIR} ./
    cd mongo-tools
    . ./set_tools_revision.sh
    sed -i '12d' buildscript/build.go
    sed -i '167,176d' buildscript/build.go
    sed -i "s:versionStr,:\"$PSMDB_TOOLS_REVISION\",:" buildscript/build.go
    sed -i "s:gitCommit):\"$PSMDB_TOOLS_COMMIT_HASH\"):" buildscript/build.go
    ./make build
    # move mongo tools to PSM installation dir
    mv bin/* ${PSMDIR_ABS}/${PSMDIR}/bin
    # end build tools
    #
    sed -i "s:TARBALL=0:TARBALL=1:" ${PSMDIR_ABS}/percona-packaging/conf/percona-server-mongodb-enable-auth.sh
    cp ${PSMDIR_ABS}/percona-packaging/conf/percona-server-mongodb-enable-auth.sh ${PSMDIR_ABS}/${PSMDIR}/bin

    # Patch needed libraries
    cd "${PSMDIR_ABS}/${PSMDIR}"
    if [ ! -d lib/private ]; then
        mkdir -p lib/private
    fi
    LIBLIST="libcrypto.so libssl.so libsasl2.so librtmp.so libssl3.so libsmime3.so libnss3.so libnssutil3.so libplds4.so libplc4.so libnspr4.so libssl3.so liblzma.so libidn.so"
    DIRLIST="bin lib/private"

    LIBPATH=""

    function gather_libs {
        local elf_path=$1
        for lib in ${LIBLIST}; do
            for elf in $(find ${elf_path} -maxdepth 1 -exec file {} \; | grep 'ELF ' | cut -d':' -f1); do
                IFS=$'\n'
                for libfromelf in $(ldd ${elf} | grep ${lib} | awk '{print $3}'); do
                    lib_realpath="$(readlink -f ${libfromelf})"
                    lib_realpath_basename="$(basename $(readlink -f ${libfromelf}))"
                    lib_without_version_suffix=$(echo ${lib_realpath_basename} | awk -F"." 'BEGIN { OFS = "." }{ print $1, $2}')

                    if [ ! -f "lib/private/${lib_realpath_basename}" ] && [ ! -L "lib/private/${lib_without_version_suffix}" ]; then
                        echo "Copying lib ${lib_realpath_basename}"
                        cp ${lib_realpath} lib/private

                        if [ ${lib_realpath_basename} != ${lib_without_version_suffix} ]; then
                            echo "Symlinking lib from ${lib_realpath_basename} to ${lib_without_version_suffix}"
                            cd lib/private
                            ln -s ${lib_realpath_basename} ${lib_without_version_suffix}
                            cd -
                        fi

                        patchelf --set-soname ${lib_without_version_suffix} lib/private/${lib_realpath_basename}

                        LIBPATH+=" $(echo ${libfromelf} | grep -v $(pwd))"
                    fi
                done
                unset IFS
            done
        done
    }

    function set_runpath {
        # Set proper runpath for bins but check before doing anything
        local elf_path=$1
        local r_path=$2
        for elf in $(find ${elf_path} -maxdepth 1 -exec file {} \; | grep 'ELF ' | cut -d':' -f1); do
            echo "Checking LD_RUNPATH for ${elf}"
            local elf_rpath=$(patchelf --print-rpath ${elf})
            if [ -z ${elf_rpath} ]; then
                echo "Changing RUNPATH for ${elf}"
                patchelf --set-rpath ${r_path} ${elf}
            else
                echo "Adding RUNPATH for ${elf}"
                patchelf --set-rpath "${elf_rpath}:${r_path}" ${elf}
            fi
        done
    }

    function replace_libs {
        local elf_path=$1
        for libpath_sorted in ${LIBPATH}; do
            for elf in $(find ${elf_path} -maxdepth 1 -exec file {} \; | grep 'ELF ' | cut -d':' -f1); do
                LDD=$(ldd ${elf} | grep ${libpath_sorted}|head -n1|awk '{print $1}')
                lib_realpath_basename="$(basename $(readlink -f ${libpath_sorted}))"
                lib_without_version_suffix="$(echo ${lib_realpath_basename} | awk -F"." 'BEGIN { OFS = "." }{ print $1, $2}')"
                if [[ ! -z $LDD  ]]; then
                    echo "Replacing lib ${lib_realpath_basename} to ${lib_without_version_suffix} for ${elf}"
                    patchelf --replace-needed ${LDD} ${lib_without_version_suffix} ${elf}
                fi
            done
        done
    }

    function create_sparse {
        local elf_path=$1
        for elf in $(find ${elf_path} -maxdepth 1 -exec file {} \; | grep 'ELF ' | cut -d':' -f1); do
            if [[ ! -f "${elf}.sparse" ]]; then
                echo "Creating sparse file of $(basename ${elf})"
                cp --sparse=always ${elf} ${elf}.sparse
            fi
        done
    }

    function replace_binaries {
        local elf_path=$1
        for elf in $(find ${elf_path} -maxdepth 1 -exec file {} \; | grep 'ELF ' | cut -d':' -f1); do
            if [[ -f "${elf}.sparse" ]]; then
                echo "Replacing binary with sparse file"
                mv ${elf}.sparse ${elf}
            fi
        done
    }

    function check_libs {
        local elf_path=$1
        for elf in $(find ${elf_path} -maxdepth 1 -exec file {} \; | grep 'ELF ' | cut -d':' -f1); do
            if ! ldd ${elf}; then
                exit 1
            fi
        done
    }

    function link {
        # Gather libs
        for DIR in ${DIRLIST}; do
            gather_libs ${DIR}
        done

        # Set proper runpath
        set_runpath bin '$ORIGIN/../lib/private/'
        set_runpath lib/private '$ORIGIN/'

        # Replace libs
        for DIR in ${DIRLIST}; do
            replace_libs ${DIR}
        done

        # Create and replace by sparse file to reduce size
        create_sparse bin
        replace_binaries bin

        # Make final check in order to determine any error after linkage
        for DIR in ${DIRLIST}; do
            check_libs ${DIR}
        done
    }

    cd ${PSMDIR_ABS}
    mv ${PSMDIR} ${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}

    if [[ ${DEBUG} = 0 ]]; then
        cp -r ${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX} ${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}-minimal
        cd ${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}-minimal
        find . -type f -exec file '{}' \; | grep ': ELF ' | cut -d':' -f1 | xargs strip --strip-unneeded
        link
        cd ${PSMDIR_ABS}
        tar --owner=0 --group=0 -czf ${WORKDIR}/${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}-minimal.tar.gz ${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}-minimal
    fi

    cd ${PSMDIR_ABS}/${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}
    link
    cd ${PSMDIR_ABS}
    tar --owner=0 --group=0 -czf ${WORKDIR}/${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}.tar.gz ${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}
    DIRNAME="tarball"
    if [ "${DEBUG}" = 1 ]; then
    DIRNAME="debug"
    fi
    mkdir -p ${WORKDIR}/${DIRNAME}
    mkdir -p ${CURDIR}/${DIRNAME}
    cp ${WORKDIR}/${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}.tar.gz ${WORKDIR}/${DIRNAME}
    cp ${WORKDIR}/${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}.tar.gz ${CURDIR}/${DIRNAME}
    if [[ ${DEBUG} = 0 ]]; then
    cp ${WORKDIR}/${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}-minimal.tar.gz ${WORKDIR}/${DIRNAME}
    cp ${WORKDIR}/${PSMDIR}-${ARCH}${GLIBC_VER}${TARBALL_SUFFIX}-minimal.tar.gz ${CURDIR}/${DIRNAME}
    fi
}

#main

CURDIR=$(pwd)
VERSION_FILE=$CURDIR/percona-server-mongodb.properties
args=
WORKDIR=
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
TARBALL=0
OS_NAME=
ARCH=
OS=
INSTALL=0
RPM_RELEASE=1
DEB_RELEASE=1
REVISION=0
BRANCH="master"
REPO="https://github.com/percona/percona-server-mongodb.git"
PSM_VER="5.0.0"
PSM_RELEASE="1"
MONGO_TOOLS_TAG="master"
PRODUCT=percona-server-mongodb
DEBUG=0
parse_arguments PICK-ARGS-FROM-ARGV "$@"
VERSION=${PSM_VER}
RELEASE=${PSM_RELEASE}
PRODUCT_FULL=${PRODUCT}-${PSM_VER}-${PSM_RELEASE}
PSM_BRANCH=${BRANCH}
if [ ${DEBUG} = 1 ]; then
  TARBALL=1
fi

check_workdir
get_system
install_deps
get_sources
build_tarball
build_srpm
build_source_deb
build_rpm
build_deb
