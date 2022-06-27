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

readonly TEMP_DIR=_devbuild/tmp

mycpp() {
  ### Run mycpp (in a virtualenv because it depends on Python 3 / MyPy)

  # created by mycpp/run.sh
  ( 
    # for _OLD_VIRTUAL_PATH error on Travis?
    set +o nounset
    set +o pipefail
    set +o errexit

    source $MYCPP_VENV/bin/activate
    time PYTHONPATH=$MYPY_REPO MYPYPATH=$REPO_ROOT:$REPO_ROOT/native \
      mycpp/mycpp_main.py "$@"
  )
}

cpp-skeleton() {
  local name=$1
  shift

  cat <<EOF
// $name.cc: translated from Python by mycpp

#include "cpp/preamble.h"  // hard-coded stuff

#undef errno  // for e->errno to work; see mycpp/myerror.h

EOF

  cat "$@"

  cat <<EOF
int main(int argc, char **argv) {
  gc_heap::gHeap.Init(400 << 20);  // 400 MiB matches dumb_alloc.cc
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

osh-eval-manifest() {
  # _devbuild is ASDL stuff
  # frontend metaprogramming: */*_def.py
  # core/process.py - not ready
  # pyutil.py -- Python only (Resource Loader, etc.)
  # pgen2/parse.py: prefer hand-written C

  # TODO: could be pyoptview,pyconsts,pymatch,pyflag

  local exclude='_devbuild/|.*_def\.py|core/py.*\.py|pybase.py|optview.py|match.py|path_stat.py|bool_stat.py|consts.py|pgen2/parse.py|oil_lang/objects.py|flag_spec.py'

  egrep -v "$exclude" types/osh-eval-manifest.txt
}

osh-eval() {
  ### Translate bin/osh_eval.py -> _build/cpp/osh_eval.{cc,h}

  local name=${1:-osh_eval}

  mkdir -p $TEMP_DIR

  local raw=$TEMP_DIR/${name}_raw.cc 

  local cc=_build/cpp/$name.cc
  local h=_build/cpp/$name.h

  # mycpp uses this, as well as compile-slice to determine the runtime library
  # TODO: Fix mylib-audit
  # export GC=1

  #if false; then
  if true; then
    # relies on splitting
    mycpp \
      --header-out $h \
      --to-header frontend.args \
      --to-header asdl.runtime \
      --to-header asdl.format \
      $(osh-eval-manifest) > $raw 
  fi

  cpp-skeleton $name $raw > $cc

  #compile-slice 'osh_eval' '.dbg'
}

#
# One off for ASDL runtime.  This is only used in tests!
#

asdl-runtime() {
  ### Translate ASDL deps for unit tests

  local gc=${1:-}  # possible suffix

  # - MESSY: asdl/runtime.h contains the SAME DEFINITIONS as
  #   _build/cpp/osh_eval.h.  But we use it to run ASDL unit tests without
  #   depending on Oil.

  local name=asdl_runtime${gc}
  local raw=$TEMP_DIR/${name}_raw.cc 

  local header=$TEMP_DIR/runtime${gc}.h

  mycpp \
    --header-out $header \
    --to-header asdl.runtime \
    --to-header asdl.format \
    $REPO_ROOT/{asdl/runtime,asdl/format,core/ansi,pylib/cgi,qsn_/qsn}.py \
    > $raw 

  { 
    if test -n "$gc"; then
      cat <<EOF
// asdl/runtime${gc}.h: GENERATED by mycpp from asdl/{runtime,format}.py

#include "_build/cpp/hnode_asdl.gc.h"
#include "cpp/qsn_qsn.h"
#include "mycpp/gc_heap.h"
#include "mycpp/mylib2.h"
EOF

    else
      cat <<EOF
// asdl/runtime.h: GENERATED by mycpp from asdl/{runtime,format}.py

#include "_build/cpp/hnode_asdl.h"
#include "cpp/qsn_qsn.h"
#include "mycpp/mylib.h"
EOF
    fi

    cat <<EOF

// For hnode::External in asdl/format.py.  TODO: Remove this when that is removed.
inline Str* repr(void* obj) {
  assert(0);
}
EOF
    cat $header

  } > asdl/runtime${gc}.h

  { cat <<EOF
// asdl/runtime${gc}.cc: GENERATED by mycpp from asdl/{runtime,format}.py

EOF
    cat $raw

  } > asdl/runtime${gc}.cc
}

asdl-runtime-gc() {
  ### Garbage-collected variant in asdl/runtime.gc.*
  GC=1 asdl-runtime '.gc'
}

diff-asdl-runtime() {
  cdiff asdl/runtime{,.gc}.h
  echo
  cdiff asdl/runtime{,.gc}.cc
}

"$@"
