#!/usr/bin/env bash
#
# Map a repo's primary-language name to the CodeQL analysis-language identifier.
#
# The reusable CI workflows carry the primary-language (e.g. `typescript`)
# end-to-end for container resolution, but a few primary-language names are not
# valid CodeQL analysis languages and must be translated for the codeql-action
# `languages:` input (epic vergil-project/.github#284 §6 point 8a):
#
#   typescript -> javascript-typescript   (bare `typescript` is not a CodeQL
#                                          analysis language; JS and TS are one
#                                          combined CodeQL language)
#   cpp        -> c-cpp                    (`c-cpp` is the current canonical
#                                          identifier; the legacy `cpp` alias is
#                                          deprecated)
#
# Every other language is a valid CodeQL identifier already and passes through
# unchanged. Both translations are routed through this one table so the mapping
# has a single home and is unit-testable (tests/resolve-language.test.sh).
#
# Writes `codeql_language=<id>` to $GITHUB_OUTPUT (and echoes the resolution).
#
# Inputs (env): LANGUAGE — the repo's primary-language name.
set -euo pipefail

case "${LANGUAGE:?LANGUAGE is required}" in
  typescript) codeql_language="javascript-typescript" ;;
  cpp) codeql_language="c-cpp" ;;
  *) codeql_language="$LANGUAGE" ;;
esac

echo "codeql_language=$codeql_language" >> "$GITHUB_OUTPUT"
echo "Resolved CodeQL analysis language: $LANGUAGE -> $codeql_language"
