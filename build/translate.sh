#!/usr/bin/env bash
#
# Wrappers for mycpp.  Might be "Pea" later.
#
# Usage:
#   build/translate.sh <function name>

set -o nounset
set -o pipefail
set -o errexit

REPO_ROOT=$(cd $(dirname $0)/.. && pwd)
readonly REPO_ROOT

source mycpp/common.sh  # MYPY_REPO

# _build/tmp/osh_eval_raw.cc won't be included in the tarball
# _build/cpp/osh_eval.cc is in the tarball
readonly TEMP_DIR=_build/tmp

mycpp() {
  ### Run mycpp (in a virtualenv because it depends on Python 3 / MyPy)

  # created by mycpp/run.sh
  ( 
    # for _OLD_VIRTUAL_PATH error on Travis?
    set +o nounset
    set +o pipefail
    set +o errexit

    source $MYCPP_VENV/bin/activate
    time PYTHONPATH=$REPO_ROOT:$MYPY_REPO MYPYPATH=$REPO_ROOT:$REPO_ROOT/native \
      mycpp/mycpp_main.py "$@"
  )
}

cpp-skeleton() {
  local name=$1
  shift

  cat <<EOF
// $name.cc: translated from Python by mycpp

#include "cpp/preamble_leaky.h"  // hard-coded stuff

#undef errno  // for e->errno to work; see mycpp/myerror.h

EOF

  cat "$@"

  cat <<EOF
int main(int argc, char **argv) {

  complain_loudly_on_segfault();

  gc_heap::gHeap.Init(400 << 20);  // 400 MiB matches dumb_alloc_leaky.cc

  // NOTE(Jesse): Turn off buffered IO
  setvbuf(stdout, 0, _IONBF, 0);
  setvbuf(stderr, 0, _IONBF, 0);

  auto* args = Alloc<List<Str*>>();
  for (int i = 0; i < argc; ++i) {
    args->append(Alloc<Str>(argv[i]));
  }
  int status = 0;

  // For benchmarking
  char* repeat = getenv("REPEAT");
  if (repeat) {
    Str* r = Alloc<Str>(repeat);
    int n = to_int(r);
    log("Running %d times", n);
    for (int i = 0; i < n; ++i) { 
      status = $name::main(args);
    }
    // TODO: clear memory?
  } else {
    status = $name::main(args);
  }

  dumb_alloc::Summarize();
  return status;
}
EOF
}


osh-eval() {
  ### Translate bin/osh_eval.py -> _build/cpp/osh_eval.{cc,h}

  local name=${1:-osh_eval}

  mkdir -p $TEMP_DIR _build/cpp

  local raw=$TEMP_DIR/${name}_raw.cc 
  local cc=_build/cpp/$name.cc
  local h=_build/cpp/$name.h

  build/app-deps.sh osh-eval

  #if false; then
  if true; then
    # relies on splitting
    cat _build/app-deps/osh_eval/translate.txt | xargs -- \
      $0 mycpp \
        --header-out $h \
        --to-header frontend.args \
        --to-header asdl.runtime \
        --to-header asdl.format \
    > $raw 
  fi

  cpp-skeleton $name $raw > $cc
}

#
# One off for ASDL runtime.  This is only used in tests!
#

asdl-runtime() {
  ### Translate ASDL deps for unit tests

  # - MESSY: asdl/runtime.h contains the SAME DEFINITIONS as
  #   _build/cpp/osh_eval.h.  But we use it to run ASDL unit tests without
  #   depending on Oil.

  local name=asdl_runtime
  local raw=$TEMP_DIR/${name}_raw.cc 

  mkdir -p $TEMP_DIR

  local header=$TEMP_DIR/runtime.h

  mycpp \
    --header-out $header \
    --to-header asdl.runtime \
    --to-header asdl.format \
    $REPO_ROOT/{asdl/runtime,asdl/format,core/ansi,pylib/cgi,qsn_/qsn}.py \
    > $raw 

  { 
    cat <<EOF
// asdl/runtime.h: GENERATED by mycpp from asdl/{runtime,format}.py

#include "_build/cpp/hnode_asdl.h"
#include "cpp/qsn_qsn.h"

#ifdef LEAKY_BINDINGS
#include "mycpp/mylib_leaky.h"
#else
#include "mycpp/gc_heap.h"
#include "mycpp/mylib2.h"
#endif

// For hnode::External in asdl/format.py.  TODO: Remove this when that is removed.
inline Str* repr(void* obj) {
  assert(0);
}
EOF
    cat $header

  } > asdl/runtime.h

  { cat <<EOF
// asdl/runtime.cc: GENERATED by mycpp from asdl/{runtime,format}.py

EOF
    cat $raw

  } > asdl/runtime.cc
}

"$@"
