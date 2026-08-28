#!/usr/bin/env bash
set -euo pipefail

# test_deploy_to_canonical.sh
#
# Proves scripts/deploy_to_canonical.sh by building throwaway FAKE fixture git
# repos under a mktemp -d directory (never touching /home/guidance/ringer_dev or
# /opt/ringer). Every case asserts the real observable outcome -- file contents,
# git log state, exit codes -- and fails loudly with a named case if wrong.
#
# Run:  bash scripts/test_deploy_to_canonical.sh

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY=$HERE/deploy_to_canonical.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

RC=0

fail() {
    printf '%s\n' "FAIL [$1]: $2"
    exit 1
}

pass() {
    printf '%s\n' "PASS [$1]"
}

repo() { # repo <dir> -- init a fresh git repo on branch main
    local d=$1
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email "test@example.invalid"
    git -C "$d" config user.name "Ringer Test"
    git -C "$d" config commit.gpgsign false
    git -C "$d" checkout -q -b main
}

put() { # put <path> <line...> -- write file, one line per arg
    local f=$1
    shift
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$@" > "$f"
}

commit_all() { # commit_all <repo> <message>
    git -C "$1" add -A
    git -C "$1" commit -q -m "$2"
}

run_deploy() { # run_deploy <logfile> <deploy-args...> -- sets global RC
    local log=$1
    shift
    set +e
    "$DEPLOY" "$@" > "$log" 2>&1
    RC=$?
    set -e
}

expect_content() { # expect_content <case> <path> <expected-content>
    local c=$1 f=$2 want=$3
    if [ ! -f "$f" ]; then
        fail "$c" "missing file '$f'"
    fi
    local got
    got=$(cat "$f")
    if [ "$got" != "$want" ]; then
        fail "$c" "file '$f' wrong content: expected '$want', got '$got'"
    fi
}

expect_log_count() { # expect_log_count <case> <repo> <expected-commits>
    local got
    got=$(git -C "$2" rev-list --count HEAD)
    if [ "$got" != "$3" ]; then
        fail "$1" "commit count: expected $3, got $got"
    fi
}

last_commit_files() { # last_commit_files <repo> -- paths touched by HEAD commit
    git -C "$1" diff-tree --no-commit-id --name-only -r HEAD
}

# ============================================================================
# (a) baseline: changed .py syncs, .toml with DIFFERENT prod content survives
#     even though dev history never touched it.
# ============================================================================
DEV=$WORK/a/dev
PROD=$WORK/a/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
put "$DEV/config.toml" 'dev_setting = "alpha"'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
commit_all "$DEV" "dev: bump app"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
put "$PROD/config.toml" 'prod_setting = "omega"'
commit_all "$PROD" "prod: initial"
TOML_BEFORE=$(cat "$PROD/config.toml")

run_deploy "$WORK/a/out.log" "$DEV" main "$PROD"
[ "$RC" -eq 0 ] || fail a "deploy exited $RC; log: $(cat "$WORK/a/out.log")"
expect_content a "$PROD/app.py" 'VERSION=2'
expect_content a "$PROD/config.toml" "$TOML_BEFORE"
[ "$(last_commit_files "$PROD")" = "app.py" ] ||
    fail a "deploy commit touched unexpected paths: $(last_commit_files "$PROD")"
pass a

# ============================================================================
# (b) exclusion holds even when dev's committed history DID change the .toml
# ============================================================================
DEV=$WORK/b/dev
PROD=$WORK/b/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
put "$DEV/config.toml" 'shared = 1'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
put "$DEV/config.toml" 'shared = 999'
commit_all "$DEV" "dev: bump app and config"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
put "$PROD/config.toml" 'shared = 1'
commit_all "$PROD" "prod: initial"
TOML_BEFORE=$(cat "$PROD/config.toml")

run_deploy "$WORK/b/out.log" "$DEV" main "$PROD"
[ "$RC" -eq 0 ] || fail b "deploy exited $RC; log: $(cat "$WORK/b/out.log")"
expect_content b "$PROD/app.py" 'VERSION=2'
expect_content b "$PROD/config.toml" "$TOML_BEFORE"
[ "$(last_commit_files "$PROD")" = "app.py" ] ||
    fail b "deploy commit touched unexpected paths: $(last_commit_files "$PROD")"
pass b

# ============================================================================
# (c) docs/*.md exclusion: changed docs in dev must never reach prod
# ============================================================================
DEV=$WORK/c/dev
PROD=$WORK/c/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
put "$DEV/docs/example.md" '# doc v1'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
put "$DEV/docs/example.md" '# doc v2 (must never reach prod)'
commit_all "$DEV" "dev: bump app and docs"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
put "$PROD/docs/example.md" '# doc v1'
commit_all "$PROD" "prod: initial"
DOC_BEFORE=$(cat "$PROD/docs/example.md")

run_deploy "$WORK/c/out.log" "$DEV" main "$PROD"
[ "$RC" -eq 0 ] || fail c "deploy exited $RC; log: $(cat "$WORK/c/out.log")"
expect_content c "$PROD/app.py" 'VERSION=2'
expect_content c "$PROD/docs/example.md" "$DOC_BEFORE"
pass c

# ============================================================================
# (d) uncommitted change to a CODE path blocks the deploy; nothing modified
# ============================================================================
DEV=$WORK/d/dev
PROD=$WORK/d/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
commit_all "$DEV" "dev: bump app"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
commit_all "$PROD" "prod: initial"
put "$PROD/app.py" 'VERSION=1-DIRTY'
HEAD_BEFORE=$(git -C "$PROD" rev-parse HEAD)

run_deploy "$WORK/d/out.log" "$DEV" main "$PROD"
[ "$RC" -ne 0 ] || fail d "deploy exited 0 but should have aborted"
grep -q 'app.py' "$WORK/d/out.log" ||
    fail d "abort message did not name blocking path; log: $(cat "$WORK/d/out.log")"
[ "$(git -C "$PROD" rev-parse HEAD)" = "$HEAD_BEFORE" ] ||
    fail d "prod HEAD changed after abort"
expect_log_count d "$PROD" 1
expect_content d "$PROD/app.py" 'VERSION=1-DIRTY'
git -C "$PROD" status --porcelain | grep -q 'app.py' ||
    fail d "dirty app.py no longer reported as dirty after abort"
pass d

# ============================================================================
# (e) uncommitted change to an EXCLUDED path (.toml) never blocks a deploy
# ============================================================================
DEV=$WORK/e/dev
PROD=$WORK/e/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
put "$DEV/config.toml" 'shared = 1'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
commit_all "$DEV" "dev: bump app"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
put "$PROD/config.toml" 'shared = 1'
commit_all "$PROD" "prod: initial"
put "$PROD/config.toml" 'shared = 1' 'prod_local_tweak = true'

run_deploy "$WORK/e/out.log" "$DEV" main "$PROD"
[ "$RC" -eq 0 ] || fail e "deploy exited $RC; log: $(cat "$WORK/e/out.log")"
expect_content e "$PROD/app.py" 'VERSION=2'
expect_content e "$PROD/config.toml" 'shared = 1
prod_local_tweak = true'
[ "$(last_commit_files "$PROD")" = "app.py" ] ||
    fail e "deploy commit touched unexpected paths: $(last_commit_files "$PROD")"
git -C "$PROD" status --porcelain | grep -q 'config.toml' ||
    fail e "uncommitted toml change was lost"
pass e

# ============================================================================
# (f) --dry-run prints the plan, exits 0, and changes nothing in prod
# ============================================================================
DEV=$WORK/f/dev
PROD=$WORK/f/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
commit_all "$DEV" "dev: bump app"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
commit_all "$PROD" "prod: initial"

run_deploy "$WORK/f/out.log" --dry-run "$DEV" main "$PROD"
[ "$RC" -eq 0 ] || fail f "dry-run exited $RC; log: $(cat "$WORK/f/out.log")"
grep -q 'app.py' "$WORK/f/out.log" ||
    fail f "dry-run did not print the file list; log: $(cat "$WORK/f/out.log")"
expect_log_count f "$PROD" 1
expect_content f "$PROD/app.py" 'VERSION=1'
if [ -n "$(git -C "$PROD" status --porcelain)" ]; then
    fail f "dry-run left prod working tree/index dirty: $(git -C "$PROD" status --porcelain)"
fi
pass f

# ============================================================================
# (g) failing test in prod's tests/ dir blocks the promotion (no new commit)
# ============================================================================
DEV=$WORK/g/dev
PROD=$WORK/g/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
put "$DEV/tests/test_gate.py" 'def test_always_fails():' '    assert False'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
commit_all "$DEV" "dev: bump app"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
put "$PROD/tests/test_gate.py" 'def test_always_fails():' '    assert False'
commit_all "$PROD" "prod: initial"

set +e
(cd "$PROD" && python3 -m pytest tests/ -q > "$WORK/g/sanity.log" 2>&1)
SANITY_RC=$?
set -e
[ "$SANITY_RC" -ne 0 ] ||
    fail g "sanity: fixture test passed but it should fail"
grep -q 'test_always_fails' "$WORK/g/sanity.log" ||
    fail g "sanity: pytest did not run the failing test (is pytest installed?); log: $(cat "$WORK/g/sanity.log")"

run_deploy "$WORK/g/out.log" "$DEV" main "$PROD"
[ "$RC" -ne 0 ] ||
    fail g "deploy exited 0 but the test gate should have blocked it"
grep -q 'test_always_fails' "$WORK/g/out.log" ||
    fail g "deploy output missing the pytest failure; log: $(cat "$WORK/g/out.log")"
expect_log_count g "$PROD" 1
pass g

# ============================================================================
# (h) one-time skill-file removal: prod copy no longer tracked after deploy
# ============================================================================
DEV=$WORK/h/dev
PROD=$WORK/h/prod
SKILL=.claude/skills/ringer/SKILL.md
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
put "$DEV/$SKILL" '# dev skill'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
commit_all "$DEV" "dev: bump app"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
put "$PROD/$SKILL" '# prod skill copy (must be removed)'
commit_all "$PROD" "prod: initial"

run_deploy "$WORK/h/out.log" "$DEV" main "$PROD"
[ "$RC" -eq 0 ] || fail h "deploy exited $RC; log: $(cat "$WORK/h/out.log")"
expect_content h "$PROD/app.py" 'VERSION=2'
if [ -n "$(git -C "$PROD" ls-files -- "$SKILL")" ]; then
    fail h "skill file still tracked in prod after deploy"
fi
[ ! -e "$PROD/$SKILL" ] || fail h "skill file still present in prod working tree"
last_commit_files "$PROD" | grep -q "$SKILL" ||
    fail h "deploy commit did not remove the skill file"
pass h

# ============================================================================
# (i) the deploy script must not contain the literal string 'sudo'
# ============================================================================
if grep -n 'sudo' "$DEPLOY" >/dev/null 2>&1; then
    fail i "the string 'sudo' appears in $DEPLOY"
fi
pass i

# ============================================================================
# (j, bonus) optional 4th arg copies the skill file to a global destination
# ============================================================================
DEV=$WORK/j/dev
PROD=$WORK/j/prod
SKILLDEST=$WORK/j/global/skills/ringer/SKILL.md
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
put "$DEV/.claude/skills/ringer/SKILL.md" '# global skill copy'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
commit_all "$DEV" "dev: bump app"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
commit_all "$PROD" "prod: initial"

run_deploy "$WORK/j/out.log" "$DEV" main "$PROD" "$SKILLDEST"
[ "$RC" -eq 0 ] || fail j "deploy exited $RC; log: $(cat "$WORK/j/out.log")"
expect_content j "$PROD/app.py" 'VERSION=2'
expect_content j "$SKILLDEST" '# global skill copy'
grep -q 'skill copy' "$WORK/j/out.log" ||
    fail j "summary did not mention the skill copy; log: $(cat "$WORK/j/out.log")"
pass j

# ============================================================================
# (k, bonus) a code file deleted in dev is removed from prod by the deploy
# ============================================================================
DEV=$WORK/k/dev
PROD=$WORK/k/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
put "$DEV/legacy.py" 'old behavior'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
rm "$DEV/legacy.py"
commit_all "$DEV" "dev: bump app and drop legacy"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
put "$PROD/legacy.py" 'old behavior'
commit_all "$PROD" "prod: initial"

run_deploy "$WORK/k/out.log" "$DEV" main "$PROD"
[ "$RC" -eq 0 ] || fail k "deploy exited $RC; log: $(cat "$WORK/k/out.log")"
expect_content k "$PROD/app.py" 'VERSION=2'
[ ! -e "$PROD/legacy.py" ] || fail k "legacy.py still present in prod after deploy"
[ -z "$(git -C "$PROD" ls-files -- legacy.py)" ] ||
    fail k "legacy.py still tracked in prod after deploy"
last_commit_files "$PROD" | grep -q 'legacy.py' ||
    fail k "deploy commit did not remove legacy.py"
pass k

# ============================================================================
# (l, bonus) --dry-run must NOT write .git/FETCH_HEAD into the prod repo:
# the throwaway clone absorbs the fetch, so the real repo's .git stays untouched
# ============================================================================
DEV=$WORK/l/dev
PROD=$WORK/l/prod
repo "$DEV"
put "$DEV/app.py" 'VERSION=1'
commit_all "$DEV" "dev: initial"
put "$DEV/app.py" 'VERSION=2'
commit_all "$DEV" "dev: bump app"
repo "$PROD"
put "$PROD/app.py" 'VERSION=1'
commit_all "$PROD" "prod: initial"
[ ! -e "$PROD/.git/FETCH_HEAD" ] ||
    fail l "sanity: prod fixture unexpectedly already has .git/FETCH_HEAD"

run_deploy "$WORK/l/out.log" --dry-run "$DEV" main "$PROD"
[ "$RC" -eq 0 ] || fail l "dry-run exited $RC; log: $(cat "$WORK/l/out.log")"
[ ! -e "$PROD/.git/FETCH_HEAD" ] ||
    fail l "dry-run wrote .git/FETCH_HEAD into the prod repo; log: $(cat "$WORK/l/out.log")"
expect_log_count l "$PROD" 1
expect_content l "$PROD/app.py" 'VERSION=1'
grep -q 'app.py' "$WORK/l/out.log" ||
    fail l "dry-run did not print the plan; log: $(cat "$WORK/l/out.log")"
pass l

printf '%s\n' "ALL TESTS PASSED (a-i required; j,k,l bonus)"
exit 0
