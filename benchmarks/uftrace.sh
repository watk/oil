#!/usr/bin/env bash
#
# Usage:
#   benchmarks/uftrace.sh <function name>
#
# Examples:
#   benchmarks/uftrace.sh record-oils-cpp
#   benchmarks/uftrace.sh replay-alloc
#   benchmarks/uftrace.sh plugin-allocs
#
# TODO:
# - uftrace dump --chrome       # time-based trace
# - uftrace dump --flame-graph  # common stack traces, e.g. for allocation

set -o nounset
set -o pipefail
set -o errexit

source test/common.sh  # R_PATH
source devtools/common.sh  # banner

readonly BASE_DIR=_tmp/uftrace

download() {
  wget --no-clobber --directory _deps \
    https://github.com/namhyung/uftrace/archive/refs/tags/v0.12.tar.gz
    #https://github.com/namhyung/uftrace/archive/v0.9.3.tar.gz
}

build() {
  cd _deps/uftrace-0.12
  ./configure
  make

  # It can't find some files unless we do this
  echo 'Run sudo make install'
}

ubuntu-hack() {
  # Annoying: the plugin engine tries to look for the wrong file?
  # What's 3.6m.so vs 3.6.so ???

  cd /usr/lib/x86_64-linux-gnu
  ln -s libpython3.6m.so.1.0 libpython3.6.so
}

# https://github.com/namhyung/uftrace/wiki/Tutorial
hello-demo() {
  cat >_tmp/hello.c <<EOF
#include <stdio.h>

int main(void) {
  printf("Hello world\n");
  return 0;
}
EOF

  gcc -o _tmp/hello -pg _tmp/hello.c

  uftrace _tmp/hello
}

record-oils-cpp() {
  ### Record a trace, but limit to allocations functions, for size

  local out_dir=$1
  local unfiltered=${2:-}
  shift 2

  #local flags=(-F process::Process::RunWait -F process::Process::Process)

  local -a flags

  if test -n "$unfiltered"; then
    out_dir=$out_dir.unfiltered

    # Look for the pattern:
    # Alloc() {
    #   MarkSweepHeap::Allocate(24)
    #   syntax_asdl::line_span::line_span()
    # }
    flags=(
      -F 'Alloc'
      -F 'MarkSweepHeap::Allocate' -A 'MarkSweepHeap::Allocate@arg2'
      -D 2
    )
    # If we don't filter at all, then it's huge
    # flags=()

  else
    # It's faster to filter just these function calls
    # Need .* for --demangle full

    flags=(
      # low level allocation
      -F 'MarkSweepHeap::Allocate.*' -A 'MarkSweepHeap::Allocate.*@arg2'

      # typed allocation
      -F 'Alloc<.*'  # missing type info

      # Flexible array allocation
      # arg 1 is str_len
      -F 'NewStr.*' -A 'NewStr.*@arg1'
      -F 'OverAllocatedStr.*' -A 'OverAllocatedStr.*@arg1'

      # This constructor doesn't matter.  We care about the interface in in
      # mycpp/gc_alloc.h
      # -F 'Str::Str.*'

      # arg1 is number of elements of type T
      -F 'NewSlab<.*' -A 'NewSlab<.*@arg1'
      # -F 'Slab<.*>::Slab.*'

      # Fixed size header allocation
      # arg2 is the number of items to reserve
      # -F 'List<.*>::List.*'
      -F 'List<.*>::reserve.*' -A 'List<.*>::reserve.*@arg2'
      # -F 'Dict<.*>::Dict.*'  # does not allocate
      -F 'Dict<.*>::reserve.*' -A 'Dict<.*>::reserve.*@arg2'

      # Common object
      # -F 'syntax_asdl::Token::Token'

      -D 1
    )

    # Problem: some of these aren't allocations
    # -F 'Tuple2::Tuple2'
    # -F 'Tuple3::Tuple3'
    # -F 'Tuple4::Tuple4'

    # StrFromC calls NewStr, so we don't need it
    # -F 'StrFromC' -A 'StrFromC@arg1' -A 'StrFromC@arg2'
  fi

  local bin=_bin/cxx-uftrace/osh
  ninja $bin

  mkdir -p $out_dir
  time uftrace record --demangle full -d $out_dir "${flags[@]}" $bin "$@"

  ls -d $out_dir/
  ls -l --si $out_dir/
}

run-tasks() {
  #local sh_path=_bin/cxx-uftrace/osh

  while read task; do

    # TODO: Could share with benchmarks/gc
    case $task in
      parse.configure-cpython)
        data_file='Python-2.7.13/configure'
        ;;
      parse.abuild)
        data_file='benchmarks/testdata/abuild'
        ;;
    esac

    # Construct argv for each task
    local -a argv
    case $task in
      parse.*)
        argv=( --ast-format none -n $data_file  )
        ;;

      ex.compute-fib)
        argv=( benchmarks/compute/fib.sh 10 44 )
        ;;

      ex.bashcomp-parse-help)
        # NOTE: benchmarks/gc.sh uses the larger clang.txt file
        argv=( benchmarks/parse-help/pure-excerpt.sh parse_help_file 
               benchmarks/parse-help/mypy.txt )
        ;;

    esac

    local out_dir=$BASE_DIR/$task/raw

    record-oils-cpp $out_dir '' "${argv[@]}"
  done
}

print-tasks() {
  # Same as benchmarks/gc
  local -a tasks=(
    # This one is a bit big
    # parse.configure-cpython

    #parse.abuild
    #ex.bashcomp-parse-help
    ex.compute-fib
  )

  for task in "${tasks[@]}"; do
    echo $task
  done
}

measure-all() {
  print-tasks | run-tasks
}

frequent-calls() {
  ### Histogram

  local out_dir=$1
  uftrace report -d $out_dir -s call --demangle full
}

call-graph() {
  ### Time-based trace

  local out_dir=$1
  uftrace graph -d $out_dir
}

tsv-plugin() {
  local task=${1:-ex.compute-fib}

  local dir=$BASE_DIR/$task/raw

  # On the big configure-coreutils script, this takes 10 seconds.  That's
  # acceptable.  Gives 2,402,003 allocations.

  local out_dir=_tmp/uftrace/$task/stage1
  mkdir -p $out_dir
  time uftrace script --demangle full -d $dir -S benchmarks/uftrace_allocs.py $out_dir

  wc -l $out_dir/*.tsv
}

R-stats() {
  local task=${1:-ex.compute-fib}

  local in_dir=$BASE_DIR/$task/stage1
  local out_dir=$BASE_DIR/$task/stage2
  mkdir -p $out_dir

  R_LIBS_USER=$R_PATH benchmarks/report.R alloc $in_dir $out_dir

  #ls $dir/*.tsv
}

report-all() {
  print-tasks | while read task; do
    banner "uftrace TASK $task"

    frequent-calls $BASE_DIR/$task/raw

    echo
  done
}

export-all() {
  # TODO: Join into a single TSV file
  print-tasks | while read task; do
    banner "uftrace TASK $task"
    time tsv-plugin $task
  done
}

analyze-all() {

  print-tasks | while read task; do
    banner "uftrace TASK $task"
    time R-stats $task
  done
}

# Hm this shows EVERY call stack that produces a list!

# uftrace graph usage shown here
# https://github.com/namhyung/uftrace/wiki/Tutorial

replay-alloc() {
  local out_dir=$1

  # call graph
  #uftrace graph -C 'MarkSweepHeap::Allocate'

  # shows what calls this function
  #uftrace replay -C 'MarkSweepHeap::Allocate'

  # shows what this function calls
  #uftrace replay -F 'MarkSweepHeap::Allocate'

  # filters may happen at record or replay time

  # depth of 1
  #uftrace replay -D 1 -F 'MarkSweepHeap::Allocate'

  uftrace replay -D 1 -F 'MarkSweepHeap::Allocate'
}

plugin() {
  # Note this one likes UNFILTERED data
  uftrace script -S benchmarks/uftrace_plugin.py
}

# TODO:
#
# - all heap allocations vs. all string allocations (include StrFromC())
#   - obj length vs. string length
#   - the -D 1 arg interferes?
# - parse workload vs evaluation workload (benchmarks/compute/*.sh)

"$@"
