#!/bin/bash
#
#  run-tests.sh
#
#  Runs every assertion suite in Tools/ and fails if any assertion does.
#
#  Each suite is a standalone Swift script that is fed the app's own source
#  files on stdin, so what it checks is what ships rather than a copy. The
#  list of sources each one needs lives in that suite's own "Run:" header,
#  and this reads the command out of the header rather than keeping a second
#  list here -- a second list is a list that drifts, and the way it drifts is
#  that a suite silently stops being run.
#
#  Usage:  Tools/run-tests.sh [suite ...]
#
#  With no arguments, every Tools/*-test.swift. With arguments, just those
#  (a bare name is fine: "disk" means Tools/disk-test.swift).
#
#  A suite must print "all passed" or "<n> failed" as its last line, and exit
#  non-zero when any assertion failed. Both, not either: the exit status alone
#  cannot tell a failed assertion from a suite that never got that far. A
#  compile error, an out-of-memory kill, and a trap inside a live IOKit call
#  all exit non-zero with no assertion having failed at all, and reporting
#  those as "failed" sends the next person looking for a bug in the thing
#  being tested. The marker is what separates them, and a suite that exits
#  non-zero without printing one is reported as not having run to completion.
#
set -u

cd "$(dirname "$0")/.." || exit 1

if [ "$#" -gt 0 ]; then
    suites=()
    for name in "$@"; do
        case "$name" in
            */*)          suites+=("$name") ;;
            *-test.swift) suites+=("Tools/$name") ;;
            *)            suites+=("Tools/$name-test.swift") ;;
        esac
    done
else
    suites=(Tools/*-test.swift)
fi

# The "Run:" line, with its backslash continuations folded back into one
# command. Everything after "Run:" up to the line that ends the pipeline.
command_for() {
    awk '
        /^\/\/[[:space:]]*Run:/ { collecting = 1; sub(/^\/\/[[:space:]]*Run:[[:space:]]*/, "") }
        collecting {
            sub(/^\/\/[[:space:]]*/, "")
            gsub(/\\$/, "")
            printf "%s ", $0
            if ($0 ~ /swift[[:space:]]*-[[:space:]]*$/) exit
        }
    ' "$1"
}

failed=()
incomplete=()
missing=()
total=0

log=$(mktemp -t roost-suite)
trap 'rm -f "$log"' EXIT

# On a CI runner, say what went wrong somewhere that can be read back.
#
# A failed job's log needs an authenticated request; its *annotations* do
# not, and `::error::` is what produces one. This workflow spent a day red
# with nobody able to see why, while `GET /actions/runs` happily reported
# the failure it could not explain.
#
# Newlines have to be encoded or the annotation stops at the first one.
annotate() {
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    local title=$1 body=$2
    body=$(printf '%s' "$body" | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')
    printf '::error title=%s::%s\n' "$title" "$body"
}

for suite in "${suites[@]}"; do
    if [ ! -f "$suite" ]; then
        echo "no such suite: $suite" >&2
        exit 1
    fi

    run=$(command_for "$suite")
    if [ -z "$run" ]; then
        # A suite with no header cannot be run, and skipping it quietly is
        # how a suite stops being run. Say so and fail at the end.
        missing+=("$suite")
        echo "=== $suite: no Run: header, skipped"
        continue
    fi

    echo "=== $suite"
    total=$((total + 1))

    # Shown as it happens and kept, so the marker can be looked for after.
    eval "$run" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}

    if grep -qE '^(all passed|[0-9]+ failed)' "$log"; then
        if [ "$status" -ne 0 ]; then
            failed+=("$suite")
            # The assertion lines themselves, not just the suite name: an
            # annotation is the only part of a failed run that can be read
            # back without a token, and "disk-test failed" sends the next
            # person to the log they cannot open.
            annotate "$suite failed" "$(grep '^  FAIL' "$log" | head -20)"
        fi
    elif [ "$status" -ne 0 ]; then
        incomplete+=("$suite (exit $status)")
        annotate "$suite did not run to completion (exit $status)" \
                 "$(tail -20 "$log")"
    else
        # Exited clean without a marker: either the suite forgot to print one
        # or it is not a suite. Either way its result means nothing.
        incomplete+=("$suite (no completion marker)")
        annotate "$suite printed no completion marker" "$(tail -5 "$log")"
    fi
done

echo
if [ "${#missing[@]}" -gt 0 ]; then
    echo "${#missing[@]} suite(s) have no Run: header:"
    printf '  %s\n' "${missing[@]}"
fi
if [ "${#incomplete[@]}" -gt 0 ]; then
    # Deliberately not called a failure. Nothing was disproved; the suite did
    # not finish, and the reason is above rather than in the assertions.
    echo "${#incomplete[@]} of $total suite(s) did not run to completion:"
    printf '  %s\n' "${incomplete[@]}"
fi
if [ "${#failed[@]}" -gt 0 ]; then
    echo "${#failed[@]} of $total suite(s) failed:"
    printf '  %s\n' "${failed[@]}"
fi
if [ "${#failed[@]}" -gt 0 ] || [ "${#incomplete[@]}" -gt 0 ] || [ "${#missing[@]}" -gt 0 ]; then
    exit 1
fi
echo "$total suite(s) passed."
