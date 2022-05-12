# Usage:
#   source build/common.sh

# Include guard.
test -n "${__BUILD_COMMON_SH:-}" && return
readonly __BUILD_COMMON_SH=1

set -o nounset
set -o pipefail
set -o errexit

# This variable shouldn't conflict with other modules.
#
# TODO: It would be much nicer to export a FUNCTION "cxx" rather than a
# variable $CXX.
_THIS_DIR=$(dirname ${BASH_SOURCE[0]})  # oilshell/oil/build/ dir
readonly _THIS_DIR
_REPO_ROOT=$(cd $_THIS_DIR/.. && pwd)  # oilshell/oil
readonly _REPO_ROOT

readonly CLANG_DIR_RELATIVE='_deps/clang+llvm-5.0.1-x86_64-linux-gnu-ubuntu-16.04'

# New version is slightly slower -- 13 seconds vs. 11.6 seconds on oil-native
#readonly CLANG_DIR_RELATIVE='../oil_DEPS/clang+llvm-14.0.0-x86_64-linux-gnu-ubuntu-18.04'

readonly CLANG_DIR=$_REPO_ROOT/$CLANG_DIR_RELATIVE
readonly CLANG=$CLANG_DIR/bin/clang  # used by benchmarks/{id,ovm-build}.sh
readonly CLANGXX=$CLANG_DIR/bin/clang++

# I'm not sure if there's a GCC version of this?
export ASAN_SYMBOLIZER_PATH=$CLANG_DIR_RELATIVE/bin/llvm-symbolizer

# equivalent of 'cc' for C++ langauge
# https://stackoverflow.com/questions/172587/what-is-the-difference-between-g-and-gcc
CXX=${CXX:-'c++'}

# Compiler flags we want everywhere.
# note: -Weverything is more than -Wall, but too many errors now.
CXXFLAGS='-std=c++11 -Wall'

readonly CLANG_COV_FLAGS='-fprofile-instr-generate -fcoverage-mapping'
readonly CLANG_LINK_FLAGS=''

readonly PY27=Python-2.7.13

readonly PREPARE_DIR=$_REPO_ROOT/../oil_DEPS/cpython-full

# Used by devtools/bin.sh and opy/build.sh
readonly OIL_SYMLINKS=(oil oilc osh oshc oven tea sh true false readlink)
readonly OPY_SYMLINKS=(opy opyc)


log() {
  echo "$@" >&2
}

die() {
  log "FATAL: $@"
  exit 1
}

source-detected-config-or-die() {
  if ! source _build/detected-config.sh; then
    # Make this error stand out.
    echo
    echo "FATAL: can't find _build/detected-config.h.  Run './configure'"
    echo
    exit 1
  fi
}
