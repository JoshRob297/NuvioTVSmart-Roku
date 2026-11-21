#!/bin/sh
# Runs the regression tests twice each: against the current working tree (must
# PASS) and against the same source files as committed in the base branch (must
# FAIL). The "before" run is reconstructed from git, so nothing has to be
# stashed or reverted.
#
#   tests/test_required_extra_catalog.brs  CatalogTask.brs
#   tests/test_notwebready_stream.brs      Streams.brs + Playback.brs
#
# Usage:  tests/run.sh [/path/to/brs] [base-ref]
#
# Requires the `brs` BrightScript interpreter (npm package "brs"). The repo has
# no test runner, so the interpreter is supplied from outside the checkout; this
# script does not add any dependency to the project.

set -e

BRS=${1:-brs}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# `brs -r` also loads <root>/components/**/*.xml, and part of the SceneGraph
# sources uses syntax this interpreter does not parse, so run with a minimal
# root that only exposes the fixtures through pkg:/.
RUNROOT=$(mktemp -d)
BEFORE=$(mktemp -d)
trap 'rm -rf "$RUNROOT" "$BEFORE"' EXIT INT TERM
ln -s "$ROOT/tests" "$RUNROOT/tests"

# brs 0.45 has no try/catch statement, and Playback.brs wraps its error handling
# in one. Removing just those keywords keeps the file parseable; the catch body
# is never reached by this test, which only exercises the early guard.
sanitize_playback() {
    sed -E '/^[[:space:]]*(try|catch([[:space:]].*)?|end[[:space:]]+try)[[:space:]]*$/d'
}

# Read-only, non-SceneGraph script files needed to execute CatalogTask.brs.
COMMON="components/I18n.brs components/Util.brs components/Store.brs components/Content.brs components/Addon.brs components/Http.brs components/ServerRows.brs"
TEST="tests/test_required_extra_catalog.brs"

# Read-only, non-SceneGraph script files needed to execute Stream_Build() and
# playStream(). Streams.brs and Playback.brs are passed per run so each
# version (base or working tree) is exercised.
WEBCOMMON="components/I18n.brs components/Util.brs"
WEBTEST="tests/test_notwebready_stream.brs"

# El "antes" sale de la rama base, no de HEAD: en un PR el fix ya esta commiteado
# y comparar contra HEAD daria PASS en las dos corridas.
# El segundo argumento es la base de este trabajo (la rama de la que se parte) y
# se usa para el test de notWebReady. El test de catalogos ya viene arreglado en
# esa rama, asi que su "antes" se toma de origin/main salvo que se pase un tercer
# argumento.
WEB_BASE=${2:-origin/main}
CAT_BASE=${3:-origin/main}
for ref in "$WEB_BASE" "$CAT_BASE"; do
    if ! git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
        echo "ERROR: no existe la referencia $ref" >&2
        exit 1
    fi
done
echo "== referencia base del test de catalogos: $CAT_BASE =="
echo "== referencia base del test de notWebReady: $WEB_BASE =="
git show "$CAT_BASE:components/tasks/CatalogTask.brs" > "$BEFORE/CatalogTask.brs"
git show "$WEB_BASE:components/Streams.brs" > "$BEFORE/Streams.brs"
git show "$WEB_BASE:components/Playback.brs" | sanitize_playback > "$BEFORE/Playback.brs"
sanitize_playback < components/Playback.brs > "$BEFORE/Playback.after.brs"

echo
echo "== antes del parche (CatalogTask.brs de $CAT_BASE) =="
set +e
"$BRS" -r "$RUNROOT" $COMMON "$BEFORE/CatalogTask.brs" "$TEST" > "$BEFORE/out.log" 2>&1
set -e
cat "$BEFORE/out.log"

echo
echo "== despues del parche (working tree) =="
"$BRS" -r "$RUNROOT" $COMMON components/tasks/CatalogTask.brs "$TEST" > "$BEFORE/after.log" 2>&1
cat "$BEFORE/after.log"

echo
echo "== antes del parche (Streams.brs y Playback.brs de $WEB_BASE) =="
set +e
"$BRS" -r "$RUNROOT" $WEBCOMMON "$BEFORE/Streams.brs" "$BEFORE/Playback.brs" "$WEBTEST" > "$BEFORE/web-before.log" 2>&1
set -e
cat "$BEFORE/web-before.log"

echo
echo "== despues del parche (working tree) =="
"$BRS" -r "$RUNROOT" $WEBCOMMON components/Streams.brs "$BEFORE/Playback.after.brs" "$WEBTEST" > "$BEFORE/web-after.log" 2>&1
cat "$BEFORE/web-after.log"

status=0
if grep -q "^RESULT: FAIL (" "$BEFORE/out.log"; then
    echo
    echo "OK: el test de catalogos falla sin el parche"
else
    echo
    echo "ERROR: el test de catalogos no falla sin el parche"
    status=1
fi
if grep -q "^RESULT: PASS (" "$BEFORE/after.log"; then
    echo "OK: el test de catalogos pasa con el parche"
else
    echo "ERROR: el test de catalogos no pasa con el parche"
    status=1
fi
if grep -q "^RESULT: FAIL (" "$BEFORE/web-before.log"; then
    echo "OK: el test de notWebReady falla sin el parche"
else
    echo "ERROR: el test de notWebReady no falla sin el parche"
    status=1
fi
if grep -q "^RESULT: PASS (" "$BEFORE/web-after.log"; then
    echo "OK: el test de notWebReady pasa con el parche"
else
    echo "ERROR: el test de notWebReady no pasa con el parche"
    status=1
fi
exit $status
