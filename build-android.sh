#!/usr/bin/env bash
set -eo pipefail

# Utilities
portable_realpath() {
    [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
}

# Configurable options
BOOST_VERSION="1.53.0"
ABI="armeabi"
LIBRARIES=""
TOOLCHAIN=""
NDK_ROOT="${NDK_ROOT:-${NDK_HOME}}"
CLEAN=no
PREFIX=""
OS="${OSTYPE//[0-9.]/}-$(uname -m)"

# If environment variables didn't do the trick, attempt to detect if
# ndk-build is available and see where it is.
if [ -z "$NDK_ROOT" ]; then
  if type ndk-build >/dev/null; then
    NDK_ROOT=$(dirname $(which ndk-build))
  fi
fi

usage() {
  cat <<USAGE
Usage: $0

  -a ABI                      ABI to build ($ABI)
  -b BOOST_VERSION            Boost version to build ($BOOST_VERSION)
  -n NDK_ROOT                 Path to NDK root (${NDK:-or set NDK_ROOT})
  -t TOOLCHAIN                Toolchain to use
  -i LIBRARY                  Include the given library (e.g. filesystem)
  -e LIBRARY                  Exclude the given library (e.g. timer)
  -c                          Clean up before building.
  -p PREFIX                   Where to build.
  -o OS                       Host OS ($OS)
  -h                          Show help.
USAGE
}

while getopts ":a:b:n:t:i:e:cp:o:h?" opt; do
  case $opt in
    a)
      ABI="$OPTARG"
      ;;
    b)
      BOOST_VERSION="$OPTARG"
      ;;
    n)
      NDK_ROOT="$OPTARG"
      ;;
    t)
      TOOLCHAIN="$OPTARG"
      ;;
    i)
      LIBRARIES="$LIBRARIES --with-$OPTARG"
      ;;
    e)
      LIBRARIES="$LIBRARIES --without-$OPTARG"
      ;;
    c)
      CLEAN=yes
      ;;
    p)
      PREFIX="$OPTARG"
      ;;
    o)
      OS="$OPTARG"
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Unknown option -$OPTARG" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Finalize options now that we've got everything
BOOST_VERSION_U="$(echo $BOOST_VERSION | tr . _)"
BOOST_DIR="boost_${BOOST_VERSION_U}"
BOOST_ARCHIVE="${BOOST_DIR}.tar.bz2"
BOOST_URL="http://downloads.sourceforge.net/project/boost/boost/${BOOST_VERSION}/${BOOST_ARCHIVE}"
PREFIX=$(portable_realpath ${PREFIX:-./build-${BOOST_VERSION}/${ABI}})

# Get NDK version for informative purposes
RELEASE_PATH="$NDK_ROOT/RELEASE.txt"
NDK_VERSION=""
NDK_ID=""
if [ -f "$RELEASE_PATH" ]; then
  NDK_VERSION=$(<"$RELEASE_PATH")
  NDK_ID="$(echo $NDK_VERSION | tr ' ' _ | tr -d '()' | cut -d - -f 1)"
else
  echo "Unsupported NDK version: ${RELEASE_PATH} not available" >&2
  exit 1
fi

# Check if the boost version is supported
JAM_PATH="configs/${NDK_ID}/${ABI}/user-config-boost-${BOOST_VERSION_U}.jam"
if [ ! -f "$JAM_PATH" ]; then
  echo "Unsupported boost version: ${JAM_PATH} not available">&2
  exit 1
fi

# Force toolchain selection to make it more obvious that just changing the
# ABI is not enough
if [ -z "$TOOLCHAIN" ]; then
  echo "Toolchain must always be selected. Options are:" >&2
  ls $NDK_ROOT/toolchains
  echo
  usage >&2
  exit 1
fi

# Check if the toolchain exists
TOOLCHAIN_PATH="$NDK_ROOT/toolchains/${TOOLCHAIN}/prebuilt/${OS}"
if [ ! -d "$TOOLCHAIN_PATH" ]; then
  echo "Toolchain not available in ${TOOLCHAIN_PATH}" >&2
  exit 1
fi

# Figure out which toolset to use
BOOST_TOOLSET="gcc-${NDK_ID}_${ABI}"

# Show selected options
cat <<EOT
Target ABI: ${ABI}
NDK root: ${NDK_ROOT}
NDK version: ${NDK_VERSION}
NDK toolchain: ${TOOLCHAIN} (${TOOLCHAIN_PATH})
Boost version: ${BOOST_VERSION}
Boost toolset: ${BOOST_TOOLSET}
Boost libraries: ${LIBRARIES}
Build prefix: ${PREFIX}
Build OS: ${OS}
EOT
echo

# Begin potentially destructive actions
echo "=====> Building boost ..."

# Make sure the prefix exists
mkdir -p "$PREFIX"

# Download source
if [ -f "$BOOST_ARCHIVE" ]; then
  echo "-----> Using ${BOOST_ARCHIVE}"
else
  echo "-----> Downloading source ..."
  wget -- "$BOOST_URL"
fi

# Clean up
echo "-----> Cleaning up previous build artifacts ..."
rm -rf -- "$BOOST_DIR"

# Unpack
echo "-----> Unpacking source ..."
tar xjf "$BOOST_ARCHIVE"

# Apply patches
echo "-----> Applying patches ..."
BOOST_PATCH_DIR="$PWD/patches/boost-${BOOST_VERSION_U}"
cp -- "${JAM_PATH}" $BOOST_DIR/tools/build/v2/user-config.jam
for patch in "$(find "$BOOST_PATCH_DIR" -name '*.patch')"; do
  (cd "$BOOST_DIR" && patch -p1 <"$patch")
done

# Bootstrap
echo "-----> Bootstrapping ..."
(cd "$BOOST_DIR" && ./bootstrap.sh 2>&1 | tee -a build.log)

# Compile
echo "-----> Compiling ..."
export PATH="$TOOLCHAIN_PATH/bin:$PATH"
export NDK_ROOT
export NO_BZIP2=1

(cd "$BOOST_DIR" && ./bjam -q                      \
  target-os=linux              \
  toolset="${BOOST_TOOLSET}"   \
  link=static                  \
  threading=multi              \
  --layout=versioned           \
  --prefix="${PREFIX}"         \
  $LIBRARIES                   \
  install 2>&1 ) | tee -a build.log

echo "=====> Build completed, artifacts available at:"
echo "       ${PREFIX}"
