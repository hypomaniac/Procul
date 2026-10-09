#!/bin/bash
# Fails if anything personal is about to be published.
#
#   scripts/privacy-check.sh              tracked files and all of history
#   scripts/privacy-check.sh build/x.zip  the same, plus the contents of a zip
#
# The strings to look for live in .private-strings, which is never committed
# because it holds the very things being kept out. One entry per line:
#
#   some words        found anywhere, ignoring case
#   re:PATTERN        an extended regular expression, ignoring case
#   ok:PATTERN        a line of findings matching this is let through
#   # comment
set -euo pipefail
cd "$(dirname "$0")/.."

LIST=.private-strings
if [ ! -f "$LIST" ]; then
    echo "privacy-check: $LIST is missing, so nothing can be checked." >&2
    echo "privacy-check: create it before publishing. The format is at the top of this script." >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

grep -v -E '^(#|re:|ok:|[[:space:]]*$)' "$LIST" > "$WORK/fixed" || true
grep -E '^re:' "$LIST" | sed 's/^re://' > "$WORK/regex" || true
grep -E '^ok:' "$LIST" | sed 's/^ok://' > "$WORK/ok" || true

if [ ! -s "$WORK/fixed" ] && [ ! -s "$WORK/regex" ]; then
    echo "privacy-check: $LIST has no entries." >&2
    exit 2
fi

# Prints path:line:text for every hit under the paths given on stdin.
scan() {
    local paths="$WORK/paths"
    cat > "$paths"
    [ -s "$paths" ] || return 0
    if [ -s "$WORK/fixed" ]; then
        tr '\n' '\0' < "$paths" | xargs -0 grep -a -H -n -i -F -f "$WORK/fixed" 2>/dev/null || true
    fi
    if [ -s "$WORK/regex" ]; then
        tr '\n' '\0' < "$paths" | xargs -0 grep -a -H -n -i -E -f "$WORK/regex" 2>/dev/null || true
    fi
}

: > "$WORK/found"

# 1. Every tracked file, and every file about to be tracked.
git ls-files --cached --others --exclude-standard | scan >> "$WORK/found"

# 2. Every commit: both names, both emails, the whole message.
git log --all --format='commit %H%nauthor %an <%ae>%ncommitter %cn <%ce>%n%B' > "$WORK/history" 2>/dev/null || true
echo "$WORK/history" | scan | sed "s|^$WORK/history|git history|" >> "$WORK/found"

# 3. Every version of every file in history. A string removed from the
#    working copy is still public if an old commit carries it.
for commit in $(git rev-list --all 2>/dev/null); do
    if [ -s "$WORK/fixed" ]; then
        git grep -a -n -i -F -f "$WORK/fixed" "$commit" -- 2>/dev/null || true
    fi
    if [ -s "$WORK/regex" ]; then
        git grep -a -n -i -E -f "$WORK/regex" "$commit" -- 2>/dev/null || true
    fi
done | sed 's/^/old commit /' >> "$WORK/found"

# 4. A release zip, if one was given.
if [ $# -ge 1 ]; then
    mkdir "$WORK/zip"
    ditto -x -k "$1" "$WORK/zip"
    find "$WORK/zip" -type f | scan | sed "s|^$WORK/zip/|zip: |" >> "$WORK/found"
fi

if [ -s "$WORK/ok" ]; then
    grep -v -i -E -f "$WORK/ok" "$WORK/found" > "$WORK/left" || true
else
    cp "$WORK/found" "$WORK/left"
fi

if [ -s "$WORK/left" ]; then
    echo "privacy-check: FAILED. Personal strings found:" >&2
    # Binary files can match with very long lines. Keep each one readable.
    cut -c1-220 "$WORK/left" | sort -u >&2
    exit 1
fi

COUNT=$(( $(wc -l < "$WORK/fixed") + $(wc -l < "$WORK/regex") ))
echo "privacy-check: clean. Checked $COUNT entries against tracked files and all of history${1:+, and $1}."
