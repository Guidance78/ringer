#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------------
# deploy_to_canonical.sh
#
# Promote code from a dev repo into a production repo safely and repeatably,
# while permanently protecting the production repo's operational, config, and
# historical files from ever being overwritten by a dev sync.
#
# Protected EXCLUDE set -- computed dynamically from the dev repo, never
# hardcoded:
#   * every tracked '*.toml' file
#   * every tracked 'docs/*.md' file
#   * every tracked file under '.claude/skills/ringer/'
#
# Usage:
#   deploy_to_canonical.sh [--dry-run] <dev-repo-path> <dev-ref> <prod-repo-path> [global-skill-dest-dir]
#
# Guarantees:
#   * never uses escalated privileges and never pushes to any remote
#   * never touches anything outside the two given repos plus the optional
#     skill destination directory
# --------------------------------------------------------------------------

usage() {
    printf '%s\n' \
        "usage: deploy_to_canonical.sh [--dry-run] <dev-repo-path> <dev-ref> <prod-repo-path> [global-skill-dest-dir]" >&2
}

# --- Argument parsing --------------------------------------------------------
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --*)       usage; exit 2 ;;
        *)         break ;;
    esac
done

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
    usage
    exit 2
fi

DEV_REPO=$1
DEV_REF=$2
PROD_REPO=$3
SKILL_DEST=${4:-}
SKILL_DIR=.claude/skills/ringer

# --- Step 1: verify prod repo exists, is git, and is not root-owned ----------
if [ ! -d "$PROD_REPO" ]; then
    printf '%s\n' "error: <prod-repo-path> '$PROD_REPO' is not a directory" >&2
    exit 1
fi
if ! git -C "$PROD_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' "error: '$PROD_REPO' is not a git repository" >&2
    exit 1
fi
if ! git -C "$DEV_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' "error: '$DEV_REPO' is not a git repository" >&2
    exit 1
fi

PROD_OWNER=$(stat -c %U "$PROD_REPO")
if [ "$PROD_OWNER" = root ]; then
    printf '%s\n' "error: <prod-repo-path> '$PROD_REPO' is owned by 'root'." >&2
    printf '%s\n' "       This deploy never escalates privileges, so it cannot operate on a" >&2
    printf '%s\n' "       root-owned repo. Fix the ownership manually as the normal user," >&2
    printf '%s\n' "       then re-run this deploy:" >&2
    printf '%s\n' "         chown -R <your-user> $PROD_REPO" >&2
    exit 1
fi

# --- Step 2: compute the EXCLUDE set from the dev repo ------------------------
EXCLUDE=$({
    git -c core.quotePath=false -C "$DEV_REPO" ls-files '*.toml' 'docs/*.md'
    git -c core.quotePath=false -C "$DEV_REPO" ls-files -- "$SKILL_DIR"
} | sort -u)

# --- Step 3: fetch the dev ref; never push anywhere ---------------------------
# A plain `git fetch` always writes .git/FETCH_HEAD in the target repo (and
# pulls the fetched objects into its object database) as an unavoidable side
# effect -- there is no flag that fetches into a real .git without touching it.
# In --dry-run mode that would silently mutate the real production repo's .git
# even though dry-run promises to change nothing, so for a dry run we clone
# $PROD_REPO into a throwaway dir (--shared reuses its object store so nothing
# is copied, --no-checkout gives no working tree) and fetch into THAT clone,
# computing every FETCH_HEAD-derived value below against it. A real deploy
# fetches straight into $PROD_REPO exactly as before, because a real deploy is
# expected to update $PROD_REPO's .git.
FETCH_BASE=$PROD_REPO
if [ "$DRY_RUN" = 1 ]; then
    FETCH_BASE=$(mktemp -d)
    if ! git clone --quiet --no-checkout --shared "$PROD_REPO" "$FETCH_BASE"; then
        printf '%s\n' "error: could not create throwaway clone of '$PROD_REPO' for --dry-run" >&2
        rm -rf "$FETCH_BASE"
        exit 1
    fi
    # Remove the throwaway clone however the script exits (success, dry-run's
    # own exit 0, or any error path). Chain onto any EXIT trap that might
    # already be registered elsewhere instead of blindly overwriting one.
    _prev_exit_trap=$(trap -p EXIT || true)
    if [ -n "$_prev_exit_trap" ]; then
        _prev_exit_trap=${_prev_exit_trap#trap -- \'}
        _prev_exit_trap=${_prev_exit_trap%\' EXIT}
        trap 'rm -rf "$FETCH_BASE"; '"$_prev_exit_trap" EXIT
    else
        trap 'rm -rf "$FETCH_BASE"' EXIT
    fi
fi

git -C "$FETCH_BASE" fetch "$DEV_REPO" "$DEV_REF"
if ! git -C "$FETCH_BASE" rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
    printf '%s\n' "error: fetch produced no FETCH_HEAD; ref '$DEV_REF' may not exist in '$DEV_REPO'" >&2
    exit 1
fi
SHORT_SHA=$(git -C "$FETCH_BASE" rev-parse --short FETCH_HEAD)

# --- Step 4: compute the CHANGED-CODE set -------------------------------------
# Every path that differs between prod HEAD and FETCH_HEAD, minus EXCLUDE.
CHANGED=$(git -c core.quotePath=false -C "$FETCH_BASE" diff --name-only HEAD FETCH_HEAD)
if [ -n "$CHANGED" ]; then
    CHANGED_CODE=$(printf '%s\n' "$CHANGED" | grep -Fxv -f <(printf '%s\n' "$EXCLUDE") || true)
else
    CHANGED_CODE=
fi

# --- Step 5: abort if any changed-code path is dirty in prod ------------------
BLOCKERS=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    p=${line:3}
    [ -n "$p" ] || continue
    if [ -n "$CHANGED_CODE" ] && printf '%s\n' "$CHANGED_CODE" | grep -Fqx -- "$p"; then
        BLOCKERS+=("$p")
    fi
done < <(git -c core.quotePath=false -C "$PROD_REPO" status --porcelain)

if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    printf '%s\n' "error: aborting deploy; uncommitted changes in <prod-repo-path> block these paths:" >&2
    for b in "${BLOCKERS[@]}"; do
        printf '%s\n' "  $b" >&2
    done
    printf '%s\n' "       Commit, stash, or discard them first; the deploy will not do it for you." >&2
    exit 1
fi

# One-time skill removal: the skill lives only in the dev repo and in the
# global skill directory; production should not track its own copy.
SKILL_TRACKED=0
if [ -n "$(git -C "$PROD_REPO" ls-files -- "$SKILL_DIR")" ]; then
    SKILL_TRACKED=1
fi

# --- Step 6a: dry run prints the plan and changes nothing ---------------------
# This branch is pure computation (read-only git queries); nothing is staged,
# committed, or written to the working tree, so there is nothing to undo.
if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n' "[dry-run] would sync '$DEV_REF' @ $SHORT_SHA from '$DEV_REPO' into '$PROD_REPO'"
    if [ -n "$CHANGED_CODE" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            if git -C "$FETCH_BASE" cat-file -e "FETCH_HEAD:$p" 2>/dev/null; then
                if git -C "$FETCH_BASE" cat-file -e "HEAD:$p" 2>/dev/null; then
                    printf '%s\n' "  M  $p"
                else
                    printf '%s\n' "  A  $p"
                fi
            else
                printf '%s\n' "  D  $p"
            fi
        done < <(printf '%s\n' "$CHANGED_CODE")
    else
        printf '%s\n' "  (no code changes to sync)"
    fi
    if [ "$SKILL_TRACKED" = 1 ]; then
        printf '%s\n' "  D  $SKILL_DIR/   (one-time skill removal)"
    fi
    printf '%s\n' "[dry-run] nothing was staged or committed."
    exit 0
fi

# --- Step 6b: stage exactly the changed-code set from FETCH_HEAD --------------
# Excluded paths are never passed to any of these commands, so they are never
# touched no matter what dev's history did to them.
if [ -n "$CHANGED_CODE" ]; then
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if git -C "$PROD_REPO" cat-file -e "FETCH_HEAD:$p" 2>/dev/null; then
            git -C "$PROD_REPO" checkout FETCH_HEAD -- "$p"
        else
            git -C "$PROD_REPO" rm -- "$p"
        fi
    done < <(printf '%s\n' "$CHANGED_CODE")
fi

# --- Step 8: real run -- test gate, then commit -------------------------------
if [ "$SKILL_TRACKED" = 1 ]; then
    git -C "$PROD_REPO" rm -r --force -- "$SKILL_DIR"
fi

TESTS_RAN=0
TESTS_PASSED=0
if [ -d "$PROD_REPO/tests" ] && [ -n "$(find "$PROD_REPO/tests" -maxdepth 1 -name '*.py' -type f -print -quit)" ]; then
    TESTS_RAN=1
    set +e
    PYTEST_OUT=$(cd "$PROD_REPO" && python3 -m pytest tests/ -q 2>&1)
    PYTEST_RC=$?
    set -e
    if [ "$PYTEST_RC" -ne 0 ]; then
        printf '%s\n' "error: tests failed in <prod-repo-path>; un-staging and aborting (nothing committed)." >&2
        printf '%s\n' "$PYTEST_OUT" >&2
        git -C "$PROD_REPO" reset
        exit 1
    fi
    TESTS_PASSED=1
fi

STAGED_STATUS=$(git -C "$PROD_REPO" diff --cached --name-status)

if [ -n "$STAGED_STATUS" ]; then
    git -C "$PROD_REPO" commit -m "deploy: sync code from $DEV_REF at $SHORT_SHA"
else
    printf '%s\n' "warning: nothing staged; no commit created" >&2
fi

# --- Step 9: optional copy of the skill directory to a global destination ------
SKILL_COPIED=0
if [ -n "$SKILL_DEST" ]; then
    if [ -d "$DEV_REPO/$SKILL_DIR" ]; then
        mkdir -p "$SKILL_DEST"
        cp -r "$DEV_REPO/$SKILL_DIR/." "$SKILL_DEST/"
        SKILL_COPIED=1
    else
        printf '%s\n' "warning: '$DEV_REPO/$SKILL_DIR' not found; skill not copied" >&2
    fi
fi

# --- Step 10: final summary -----------------------------------------------------
printf '%s\n' "deploy summary:"
printf '%s\n' "  dev source:   $DEV_REPO @ $DEV_REF ($SHORT_SHA)"
printf '%s\n' "  prod target:  $PROD_REPO"
printf '%s\n' "  dry run:      no"
if [ -n "$STAGED_STATUS" ]; then
    printf '%s\n' "  files changed in prod:"
    while IFS= read -r line; do
        printf '%s\n' "    $line"
    done <<< "$STAGED_STATUS"
else
    printf '%s\n' "  files changed in prod: (none)"
fi
if [ "$TESTS_RAN" = 1 ]; then
    if [ "$TESTS_PASSED" = 1 ]; then
        printf '%s\n' "  tests:        ran (pytest tests/) and passed"
    else
        printf '%s\n' "  tests:        ran (pytest tests/) and FAILED"
    fi
else
    printf '%s\n' "  tests:        not run (no tests/ dir with *.py in prod)"
fi
if [ -n "$SKILL_DEST" ]; then
    if [ "$SKILL_COPIED" = 1 ]; then
        printf '%s\n' "  skill copy:   copied to $SKILL_DEST"
    else
        printf '%s\n' "  skill copy:   not copied"
    fi
else
    printf '%s\n' "  skill copy:   skipped (no destination given)"
fi
