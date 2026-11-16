#!/usr/bin/env bash
#
# build-gate.sh <build-enabled> <build-result>
#
# The quality evidence gate's decision on ci-quality.yml's `build` job (epic
# vergil-project/.github#1174, Task 6). The job runs only when vergil-tooling
# turns the BUILD check on for the repo's language, which `vrg-ci-resolve`
# reports as `build-enabled`. No language list lives here: the flag is the one
# source.
#
#   <build-enabled> — the `matrix` job's `build-enabled` output, "true" or
#                     "false".
#   <build-result>  — `needs.build.result`: success, failure, cancelled or
#                     skipped.
#
# Exits 0 for exactly two pairs: (false, skipped) and (true, success). Every
# other pair exits 1 with an ::error:: naming what is wrong: BUILD on and the
# job not successful (a skipped job included, so a build that should have run
# never passes by absence), BUILD off and the job not skipped, or a flag or
# result outside the values above. Exits 2 on a usage error.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: build-gate.sh <build-enabled> <build-result>" >&2
  exit 2
fi

enabled="$1"
result="$2"

case "$enabled" in
  true | false) ;;
  *)
    echo "::error::build-enabled is '${enabled}', expected 'true' or 'false'" \
      "(the matrix job's build-enabled output, from vrg-ci-resolve)" >&2
    exit 1
    ;;
esac

case "$result" in
  success | failure | cancelled | skipped) ;;
  *)
    echo "::error::build result is '${result}', expected success, failure," \
      "cancelled or skipped (needs.build.result)" >&2
    exit 1
    ;;
esac

if [ "$enabled" = true ]; then
  if [ "$result" != success ]; then
    echo "::error::BUILD is on for this repo's language, but the build job" \
      "did not succeed (result: '${result}')" >&2
    exit 1
  fi
  echo "build gate: BUILD is on and the build job succeeded"
else
  if [ "$result" != skipped ]; then
    echo "::error::BUILD is off for this repo's language, but the build job" \
      "was not skipped (result: '${result}')" >&2
    exit 1
  fi
  echo "build gate: BUILD is off and the build job was skipped"
fi
