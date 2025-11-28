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

# A normal clone checks out ciphertext before the repository-local filters exist.
# Decrypt those filtered working-tree files directly; manipulating the index here
# would invoke the clean filter on ciphertext and fail before smudge can run.
echo "🔁 Decrypting filtered files in the working tree..."
"$SCRIPT" decrypt

# Force git to update status
sleep .5
git status &>/dev/null

echo "✅ Filtered files decrypted."
