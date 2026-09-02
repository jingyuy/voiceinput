#!/usr/bin/env bash

# Run a sequential, human-controlled feature workflow in Herdr.
# Usage: ./scripts/herdr-team.sh "Add a simple application settings screen"
# This runner never merges or pushes. It requests human review only after a
# clean implementation commit has passed independent test and Master review.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 \"feature request\""
    exit 1
fi

REQUEST="$*"
SLUG="$(printf '%s' "$REQUEST" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-45)"
[[ -n "$SLUG" ]] || { echo "ERROR: Could not create a task id."; exit 1; }
TASK_ID="$(date '+%Y%m%d-%H%M%S')-$SLUG"

TASK_DIR="$ROOT/.ai/tasks/$TASK_ID"
RUN_DIR="$ROOT/.ai/runs/$TASK_ID"
ARCH_BRANCH="agent/architect-$TASK_ID"
IMPLEMENT_BRANCH="agent/implement-$TASK_ID"
TEST_BRANCH="agent/test-$TASK_ID"
MASTER_BRANCH="agent/master-$TASK_ID"
ARCH_WORKTREE="$ROOT-$TASK_ID-architect"
IMPLEMENT_WORKTREE="$ROOT-$TASK_ID-implementer"
TEST_WORKTREE="$ROOT-$TASK_ID-tester"
MASTER_WORKTREE="$ROOT-$TASK_ID-master"
ARCH_AGENT="arch-${TASK_ID:0:27}"
IMPLEMENT_AGENT="impl-${TASK_ID:0:27}"
TEST_AGENT="test-${TASK_ID:0:27}"
MASTER_AGENT="master-${TASK_ID:0:25}"

require() {
    command -v "$1" >/dev/null || { echo "ERROR: $1 is required."; exit 1; }
}

create_worktree() {
    local branch="$1" base="$2" path="$3" label="$4"
    local response pane
    response="$(herdr worktree create --cwd "$ROOT" --branch "$branch" --base "$base" --path "$path" --label "$label" --focus)"
    pane="$(printf '%s\n' "$response" | jq -r '.result.root_pane.pane_id // empty')"
    [[ -n "$pane" ]] || { echo "ERROR: Herdr did not return a pane for $label."; exit 1; }
    printf '%s\n' "$pane"
}

start_and_prompt() {
    local name="$1" pane="$2" prompt="$3"
    herdr agent start "$name" --kind codex --pane "$pane" --timeout 120000
    herdr agent prompt "$pane" "$prompt" --wait --timeout 900000
}

test_passed() {
    grep -A2 -E '^## Result$' "$1" | grep -qx 'PASS'
}

require git
require herdr
require codex
require jq
git rev-parse --verify main >/dev/null || { echo "ERROR: main branch not found."; exit 1; }

if [[ "${HERDR_ENV:-}" != "1" ]]; then
    echo "ERROR: Run this command from a Herdr-managed pane (HERDR_ENV=1)."
    exit 1
fi

if [[ -n "$(git status --short)" ]]; then
    echo "ERROR: The checkout has uncommitted changes. Commit, stash, or use a clean checkout before starting."
    git status --short
    exit 1
fi

mkdir -p "$TASK_DIR" "$RUN_DIR"
printf '%s\n' "$REQUEST" > "$RUN_DIR/request.txt"
cat > "$TASK_DIR/REQUEST.md" <<EOF
# Feature Request

$REQUEST
EOF

echo "Starting task $TASK_ID"

ARCH_PANE="$(create_worktree "$ARCH_BRANCH" main "$ARCH_WORKTREE" "Architect - $TASK_ID")"
start_and_prompt "$ARCH_AGENT" "$ARCH_PANE" "You are the Architect for task '$TASK_ID'. Read .ai/architect.md and .ai/master.md. Inspect the actual repository, then write .ai/tasks/$TASK_ID/ARCHITECTURE.md. Do not change production code, merge, or push. End with APPROVED only if the proposal is implementable."
ARCH_DOC="$ARCH_WORKTREE/.ai/tasks/$TASK_ID/ARCHITECTURE.md"
[[ -f "$ARCH_DOC" ]] || { echo "ERROR: Architect did not write ARCHITECTURE.md."; exit 1; }
cp "$ARCH_DOC" "$TASK_DIR/ARCHITECTURE.md"

IMPLEMENT_PANE="$(create_worktree "$IMPLEMENT_BRANCH" main "$IMPLEMENT_WORKTREE" "Implementer - $TASK_ID")"
mkdir -p "$IMPLEMENT_WORKTREE/.ai/tasks/$TASK_ID"
cp "$TASK_DIR/REQUEST.md" "$TASK_DIR/ARCHITECTURE.md" "$IMPLEMENT_WORKTREE/.ai/tasks/$TASK_ID/"
start_and_prompt "$IMPLEMENT_AGENT" "$IMPLEMENT_PANE" "You are the Implementer for task '$TASK_ID'. Read .ai/implementer.md, plus REQUEST.md and ARCHITECTURE.md in .ai/tasks/$TASK_ID. Implement the approved design in this worktree, run relevant checks, write IMPLEMENTATION.md, and create one or more feature commits. Do not merge or push."
IMPLEMENT_DOC="$IMPLEMENT_WORKTREE/.ai/tasks/$TASK_ID/IMPLEMENTATION.md"
[[ -f "$IMPLEMENT_DOC" ]] || { echo "ERROR: Implementer did not write IMPLEMENTATION.md."; exit 1; }
[[ -z "$(git -C "$IMPLEMENT_WORKTREE" status --short)" ]] || { echo "ERROR: Implementer worktree is dirty; it must be clean before review."; exit 1; }
IMPLEMENT_HEAD="$(git -C "$IMPLEMENT_WORKTREE" rev-parse HEAD)"
[[ "$IMPLEMENT_HEAD" != "$(git rev-parse main)" ]] || { echo "ERROR: Implementer created no commit."; exit 1; }
cp "$IMPLEMENT_DOC" "$TASK_DIR/IMPLEMENTATION.md"

TEST_PANE="$(create_worktree "$TEST_BRANCH" "$IMPLEMENT_BRANCH" "$TEST_WORKTREE" "Tester - $TASK_ID")"
mkdir -p "$TEST_WORKTREE/.ai/tasks/$TASK_ID"
cp "$TASK_DIR/REQUEST.md" "$TASK_DIR/ARCHITECTURE.md" "$TASK_DIR/IMPLEMENTATION.md" "$TEST_WORKTREE/.ai/tasks/$TASK_ID/"
start_and_prompt "$TEST_AGENT" "$TEST_PANE" "You are the independent Tester for task '$TASK_ID'. Read .ai/tester.md and the task documents. Review the implementation commit and run relevant checks. Write .ai/tasks/$TASK_ID/TEST-REPORT.md with PASS or FAIL. Do not change production code, merge, or push."
TEST_DOC="$TEST_WORKTREE/.ai/tasks/$TASK_ID/TEST-REPORT.md"
[[ -f "$TEST_DOC" ]] || { echo "ERROR: Tester did not write TEST-REPORT.md."; exit 1; }
cp "$TEST_DOC" "$TASK_DIR/TEST-REPORT.md"

# The first failure is routed back to the same Implementer worktree. The Tester
# then fast-forwards to the new commit and repeats its independent review.
FIX_ATTEMPTS=0
while ! test_passed "$TEST_DOC"; do
    ((FIX_ATTEMPTS += 1))
    if (( FIX_ATTEMPTS > 2 )); then
        echo "ERROR: Tester still reports FAIL after two fix attempts; inspect $TASK_DIR/TEST-REPORT.md."
        exit 1
    fi

    PREVIOUS_HEAD="$IMPLEMENT_HEAD"
    cp "$TASK_DIR/TEST-REPORT.md" "$IMPLEMENT_WORKTREE/.ai/tasks/$TASK_ID/TEST-REPORT.md"
    herdr agent prompt "$IMPLEMENT_PANE" "The Tester reported FAIL for task '$TASK_ID'. Read .ai/tasks/$TASK_ID/TEST-REPORT.md, fix every required issue in this worktree, rerun relevant checks, update IMPLEMENTATION.md, and commit the fixes. Do not merge or push." --wait --timeout 900000
    [[ -z "$(git -C "$IMPLEMENT_WORKTREE" status --short)" ]] || { echo "ERROR: Implementer worktree is dirty after the fix attempt."; exit 1; }
    IMPLEMENT_HEAD="$(git -C "$IMPLEMENT_WORKTREE" rev-parse HEAD)"
    [[ "$IMPLEMENT_HEAD" != "$PREVIOUS_HEAD" ]] || { echo "ERROR: Implementer did not commit a fix after the test failure."; exit 1; }
    cp "$IMPLEMENT_WORKTREE/.ai/tasks/$TASK_ID/IMPLEMENTATION.md" "$TASK_DIR/IMPLEMENTATION.md"

    git -C "$TEST_WORKTREE" merge --ff-only "$IMPLEMENT_BRANCH"
    herdr agent prompt "$TEST_PANE" "The Implementer committed a fix for task '$TASK_ID'. Re-read the updated implementation and repeat the independent review. Replace .ai/tasks/$TASK_ID/TEST-REPORT.md with PASS or FAIL. Do not modify production code, merge, or push." --wait --timeout 900000
    [[ -f "$TEST_DOC" ]] || { echo "ERROR: Tester did not update TEST-REPORT.md."; exit 1; }
    cp "$TEST_DOC" "$TASK_DIR/TEST-REPORT.md"
done

MASTER_PANE="$(create_worktree "$MASTER_BRANCH" "$IMPLEMENT_BRANCH" "$MASTER_WORKTREE" "Master review - $TASK_ID")"
mkdir -p "$MASTER_WORKTREE/.ai/tasks/$TASK_ID"
cp "$TASK_DIR/REQUEST.md" "$TASK_DIR/ARCHITECTURE.md" "$TASK_DIR/IMPLEMENTATION.md" "$TASK_DIR/TEST-REPORT.md" "$MASTER_WORKTREE/.ai/tasks/$TASK_ID/"
start_and_prompt "$MASTER_AGENT" "$MASTER_PANE" "You are the Master final reviewer for task '$TASK_ID'. Read .ai/master.md and every task document. Independently inspect the implementation commit and verify the reported checks. Write .ai/tasks/$TASK_ID/MASTER-REVIEW.md. Put APPROVED FOR HUMAN REVIEW on a line by itself only if the feature is ready for a human to validate, merge, and push. Do not modify production code, merge, or push."
MASTER_DOC="$MASTER_WORKTREE/.ai/tasks/$TASK_ID/MASTER-REVIEW.md"
[[ -f "$MASTER_DOC" ]] || { echo "ERROR: Master did not write MASTER-REVIEW.md."; exit 1; }
cp "$MASTER_DOC" "$TASK_DIR/MASTER-REVIEW.md"
grep -qx 'APPROVED FOR HUMAN REVIEW' "$MASTER_DOC" || { echo "ERROR: Master did not approve; inspect $TASK_DIR/MASTER-REVIEW.md."; exit 1; }

echo
echo "========================================"
echo "HUMAN REVIEW REQUIRED"
echo "========================================"
echo "Implementation commit: $IMPLEMENT_HEAD"
echo "Implementation branch: $IMPLEMENT_BRANCH"
echo "Task reports:          $TASK_DIR"
echo
echo "Review the commit and reports, run final device validation, then merge and push if satisfied."
read -r -p "Press Enter after you have reviewed this handoff (the script will not merge or push): "
