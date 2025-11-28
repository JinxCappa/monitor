#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/git-sops.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "❌ $SCRIPT not found or not executable" >&2
  exit 1
fi

echo "✅ Wiring git-sops filters using $SCRIPT"

# Filter config (absolute paths)
git config --local --replace-all filter.crypt.required true
git config --local --replace-all filter.crypt.smudge "$SCRIPT smudge %f"
git config --local --replace-all filter.crypt.clean  "$SCRIPT clean %f"

# Diff config
git config --local --replace-all diff.crypt.textconv "$SCRIPT clean %f"

# ⚠ This will overwrite local changes in tracked files
echo "🔁 Forcing re-checkout of all tracked files so smudge filters run..."
# Remove files from working directory but keep in index
git rm --cached -r .

# Restore files, forcing smudge filters to run
git reset --hard HEAD

# Force git to update status
sleep .5
git status &>/dev/null

echo "✅ Re-checkout done."