#!/usr/bin/env bash
#
# Count lines of code in various ways.
#
# Usage:
#   metrics/source-code.sh <function name>

set -o nounset
set -o pipefail
set -o errexit

filter-py() {
  grep -E -v '__init__.py$|_gen.py|_test.py|_tests.py$'
}

readonly -a ASDL_FILES=( {frontend,core}/*.asdl )

# OSH and common
osh-files() {
  # Exclude:
  # - line_input.c because I didn't write it.  It still should be minimized.
  # - code generators
  # - test library

  ls bin/oil.py {osh,core,frontend,qsn_}/*.py native/*.c */*.pyi "${ASDL_FILES[@]}" \
    | filter-py | grep -E -v 'posixmodule.c$|line_input.c$|_gen.py$|test_lib.py$|os.pyi$'
}

oil-lang-files() {
  ls oil_lang/*.{py,pgen2} tea/*.py | filter-py 
}

# cloc doesn't understand ASDL files.
# Use a wc-like format, filtering out blank lines and comments.
asdl-cloc() {
  python -c '
import sys

total = 0
for path in sys.argv[1:]:
  num_lines = 0
  with open(path) as f:
    for line in f:
      line = line.strip()
      if not line or line.startswith("--"):
        continue
      num_lines += 1

  print "%5d %s" % (num_lines, path)
  total += num_lines

print "%5d %s" % (total, "total")
' "$@"
}

osh-cloc() {
  echo 'OSH (non-blank non-comment lines)'
  echo
  osh-files | xargs cloc --quiet "$@"

  # NOTE: --csv option could be parsed into HTML.
  # Or just sum with asdl-cloc!

  echo
  echo 'ASDL SCHEMAS (non-blank non-comment lines)'
  asdl-cloc "${ASDL_FILES[@]}"
}

#
# Two variants: text and html
#

category-text() {
  local header=$1
  local comment=$2

  echo "$header"
  # omit comment

  # stdin is the files
  xargs wc -l | sort --numeric
  echo
}

# This is overly clever ...
shopt -s lastpipe
SECTION_ID=0  # mutable global

category-html() {
  xargs wc -l | metrics/line_counts.py $((++SECTION_ID)) "$@"
}

#
# Functions That Count
#

# Note this style is OVERLY ABSTRACT, but it's hard to do better in shell.  We
# want to parameterize over text and HTML.  In Oil I think we would use this:
#
# proc p1 {
#   category 'OSH (and common libraries)' {
#     comment = 'This is the input'
#     osh-files | read --lines :files
#   }
# }
#
# This produces a series of dicts that looks like
# { name: 'OSH ...', comment: "This ...", files: %(one two three) }
#
# Then we iterate over the categories and produce text or HTML.

osh-counts() {
  local count=$1
  shift

  osh-files | $count \
    'OSH (and common libraries)' \
    'This is the input to the translator, written in statically-typed Python.' \
    "$@"
}

cpp-counts() {
  local count=$1
  shift

  ls cpp/*.{cc,h} | egrep -v 'greatest.h|unit_tests.cc' | $count \
    'Hand-written C++ Code, like OS bindings' \
    'The small C++ files correspond to larger Python files, like osh/arith_parse.py.' \
    "$@"

  ls mycpp/mylib.{cc,h} | $count \
    'Old mycpp Runtime' \
    'This implementation has no garbage collection; it allocates memory forever.' \
    "$@"

  ls mycpp/gc_heap.* mycpp/mylib2.* mycpp/my_runtime.* | $count \
    'New Garbage-Collected Runtime' \
    '' \
    "$@"

  ls mycpp/*_test.cc cpp/unit_tests.cc | $count \
    'Unit tests in C++' \
    '' \
    "$@"
}

gen-cpp-counts() {
  local count=$1
  shift

  # NOTE: this excludes .re2c.h file
  ls _build/cpp/*.{cc,h} _devbuild/gen/*.h | $count \
    'Generated C+ Code' \
    'mycpp generates only the big file _build/cpp/osh_eval.cc.  Other code generators, including Zephyr ASDL and re2c, produce the other files.' \
    "$@"
}

mycpp-counts() {
  local count=$1
  shift

  ls mycpp/*.py | grep -v 'build_graph.py' | filter-py | $count \
    'mycpp translator' \
    "This prototype uses the MyPy frontend to translate statically-typed Python to C++.  The generated C++ makes use of a small runtime for things like List<T>, Dict<K, V>, and Python's len()." \
    "$@"

  ls mycpp/examples/*.py | $count \
    'mycpp testdata' \
    'Small Python examples that translate to C++, compile, and run.' \
    "$@"
}

#
# Top Level Summaries
#

for-translation() {
  local count=$1
  shift

  mycpp-counts $count "$@"

  cpp-counts $count "$@"

  osh-counts $count "$@"

  gen-cpp-counts $count "$@"
}

overview() {
  local count=$1
  shift

  osh-counts $count "$@"

  oil-lang-files | $count \
    'Oil Language (and Tea)' '' "$@"

  ls pylib/*.py | filter-py | $count \
    "Code borrowed from Python's stdlib" '' "$@"

  ls qsn_/*.py | filter-py | $count \
    'QSN library' '' "$@"

  ls spec/*.test.sh | $count \
    'Spec Tests' '' "$@"

  ls {osh,oil_lang,frontend,core,native}/*_test.py | $count \
    'Language Unit Tests' '' "$@"

  ls {build,test,asdl,pylib,tools}/*_test.py | $count \
    'Other Unit Tests' '' "$@"

  ls test/gold/*.sh | $count \
    'Gold Tests' '' "$@"

  mycpp-counts $count "$@"

  # Leaving off cpp-counts since that requires a C++ build

  ls build/*.{mk,sh,py} Makefile *.mk configure install | filter-py | $count \
    'Build Automation' '' "$@"

  ls test/*.{sh,py,R} | filter-py | grep -v jsontemplate.py | $count \
    'Test Automation' '' "$@"

  ls devtools/release*.sh | $count \
    'Release Automation' '' "$@"

  ls soil/*.{sh,py} | $count \
    'Soil (multi-cloud continuous build with containers)' '' "$@"

  ls benchmarks/*.{sh,py,R} | $count \
    'Benchmarks' '' "$@"

  ls metrics/*.{sh,R} | $count \
    'Metrics' '' "$@"

  ls asdl/*.py | filter-py | grep -v -E 'arith_|tdop|_demo' | $count \
    'Zephyr ASDL' '' "$@"

  ls pgen2/*.py | filter-py | $count \
    'pgen2 (parser generator)' '' "$@"

  ls */*_gen.py | $count \
    'Other Code Generators' '' "$@"

  ls _devbuild/gen/*.{py,h} | $count \
    'Generated Python Code' \
    'For the Python App Bundle.' \
    "$@"

  ls tools/*.py | filter-py | $count \
    'Tools' '' "$@"

  ls {doctools,lazylex}/*.py | filter-py | $count \
    'Dco Tools' '' "$@"

  ls web/*.js web/*/*.{js,py} | $count \
    'Web' '' "$@"
}

for-translation-text() {
  for-translation category-text
}

overview-text() {
  overview category-text
}

#
# HTML Versions
#

html-head() {
  PYTHONPATH=. doctools/html_head.py "$@"
}

metrics-html-head() {
  local title="$1"

  local base_url='../../../web'

  html-head --title "$title" "$base_url/base.css" "$base_url/table/table-sort.css" "$base_url/line-counts.css" 
}

tsv2html() {
  web/table/csv2html.py --tsv "$@"
}

counts-html() {
  local name=$1
  local title=$2

  local tmp_dir=_tmp/metrics/line-counts/$name

  rm -r -f -v $tmp_dir >& 2
  mkdir -v -p $tmp_dir >& 2

  echo $'category\tcategory_HREF\ttotal_lines\tnum_files' > $tmp_dir/INDEX.tsv

  echo $'column_name\ttype
category\tstring
category_HREF\tstring
total_lines\tinteger
num_files\tinteger' >$tmp_dir/INDEX.schema.tsv 

  # Generate the HTML
  $name category-html $tmp_dir

  metrics-html-head "$title"
  echo '  <body class="width40">'

  echo "<h1>$title</h1>"

  tsv2html $tmp_dir/INDEX.tsv

  # All the parts
  cat $tmp_dir/*.html

  echo '  </body>'
  echo '</html>'
}

for-translation-html() {
  local title='Code Overview: Translating Oil to C++'
  counts-html for-translation "$title"
}

overview-html() {
  local title='Overview of Oil Code'
  counts-html overview "$title"
}

write-reports() {
  # TODO:
  # - Put these in the right directory.
  # - Link from release page

  local dir=_tmp/metrics/line-counts

  mkdir -v -p $dir

  for-translation-html > $dir/for-translation.html

  overview-html > $dir/overview.html

  cat >$dir/index.html <<EOF
<a href="for-translation.html">for-translation</a> <br/>
<a href="overview.html">overview</a> <br/>
EOF

  ls -l $dir
}

#
# Misc
#

# count instructions, for fun
instructions() {
  # http://pepijndevos.nl/2016/08/24/x86-instruction-distribution.html

  local bin=_build/oil/ovm-opt.stripped
  objdump -d $bin | cut -f3 | grep -oE "^[a-z]+" | hist
}

hist() {
  sort | uniq -c | sort -n
}

stdlib-imports() {
  oil-osh-files | xargs grep --no-filename '^import' | hist
}

imports() {
  oil-osh-files | xargs grep --no-filename -w import | hist
}

imports-not-at-top() {
  oil-osh-files | xargs grep -n -w import | awk -F : ' $2 > 100'
}

# For the compiler, see what's at the top level.
top-level() {
  grep '^[a-zA-Z]' {core,osh}/*.py \
    | grep -v '_test.py'  \
    | egrep -v ':import|from|class|def'  # note: colon is from grep output
}

_python-symbols() {
  local main=$1
  local name=$2
  local out_dir=$3

  mkdir -p $out_dir
  local out=${out_dir}/${name}-symbols.txt

  # Run this from the repository root.
  PYTHONPATH='.:vendor/' CALLGRAPH=1 $main | tee $out

  wc -l $out
  echo 
  echo "Wrote $out"
}

oil-python-symbols() {
  local out_dir=${1:-_tmp/opy-test}
  _python-symbols bin/oil.py oil $out_dir
}

opy-python-symbols() {
  local out_dir=${1:-_tmp/opy-test}
  _python-symbols bin/opy_.py opy $out_dir
}

old-style-classes() {
  oil-python-symbols | grep -v '<'
}

# Some of these are "abstract classes" like ChildStateChange
NotImplementedError() {
  grep NotImplementedError */*.py
}

if test $(basename $0) = 'source-code.sh'; then
  "$@"
fi
