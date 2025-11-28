#!/usr/bin/env bash

# This script integrates the `sops` secrets management tool with Git, providing
# functionality to initialize repositories with a custom clean and smudge filter
# that enables automatic encryption and decryption of files defined for use with
# this filter in .gitattributes (e.g. `.env* filter=crypt`).

set -eo pipefail

if [[ -z "${SOPS_AGE_KEY:-}" ]]; then
	if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
		export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
	fi

	if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
		echo "Error: no SOPS age identity configured" >&2
		echo "Set SOPS_AGE_KEY to an age identity or SOPS_AGE_KEY_FILE to an identity file." >&2
		exit 1
	fi
fi

sops_age_identity_source() {
	if [[ -n "${SOPS_AGE_KEY:-}" ]]; then
		echo "SOPS_AGE_KEY"
	else
		echo "SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-}"
	fi
}

self_path=$(realpath "$0")
sops_config="$(dirname "$self_path")/../.sops.yaml"

git_filter_name=crypt
encryption_marker="ENC[AES256"

# Encryption mode: auto (default, matches sops — picks type from extension,
# preserves key names) or binary (opaque, hides structure). Select via the
# -b/--binary flag; init() bakes the flag into .git/config's filter commands
# so git-invoked smudge/clean inherit the choice.
# Note: switching modes after files are encrypted requires re-encrypting them,
# since sops needs the original type on decrypt.
binary_mode=false

# Check if a file exists in HEAD
exists_in_head() {
	local file="$1"
	git cat-file -e "HEAD:$file" &> /dev/null
}

# Check if a file is encrypted by searching for the encryption marker
is_encrypted() {
	local file=$1
	grep -Fq "$encryption_marker" "$file"
}

# Check if the working copy of a file actually differs from its decrypted content in HEAD
is_changed() {
	local file="$1"
	local file_type

	# If the file does not exist in HEAD, consider it changed (new file)
	if ! exists_in_head "$file"; then
		return 0
	fi

	file_type=$(get_file_type "$file")

	if ! is_encrypted "$file"; then
		# Decrypt HEAD blob to a temp file so sops failures surface as hard
		# errors. With process substitution, secrets' exit 1 only kills the
		# subshell — cmp would then see truncated output and report "differ",
		# silently causing clean() to re-encrypt stale plaintext.
		local tmp
		tmp=$(mktemp)
		trap 'rm -f "$tmp"' EXIT INT TERM
		if ! git cat-file -p "HEAD:$file" | secrets decrypt "$file" "$file_type" > "$tmp"; then
			exit 1
		fi
		local result=0
		cmp -s "$file" "$tmp" && result=1
		rm -f "$tmp"
		trap - EXIT INT TERM
		return $result
	else
		# Working-tree copy is ciphertext — smudge didn't run (fresh clone
		# without filters, failed smudge, manual copy). Comparing ciphertexts
		# byte-for-byte is meaningless (fresh nonces per encrypt) and letting
		# clean proceed would feed ciphertext through sops encrypt.
		echo "Error: $file contains ciphertext in the working tree." >&2
		echo "Run '$self_path decrypt' or re-checkout before staging." >&2
		exit 1
	fi
}

# Determine file type for sops encryption
get_file_type() {
	local file="$1"

	if $binary_mode; then
		echo "binary"
		return
	fi

	# Extension-based detection. Unknown extensions fall back to binary so
	# sops doesn't fail on files it can't parse structurally.
	case "$file" in
		*.json)            echo "json" ;;
		*.yaml|*.yml)      echo "yaml" ;;
		.env|*.env|.env.*) echo "dotenv" ;;
		*)                 echo "binary" ;;
	esac
}

# Encrypt/decrypt file content via sops (reads stdin, writes stdout)
secrets() {
	local action=$1
	local file=$2
	local file_type=$3

	if [[ "$action" != @(encrypt|decrypt) ]]; then
		echo "Error: Invalid action. Use 'encrypt' or 'decrypt'" >&2
		exit 1
	fi

	if ! sops --config "$sops_config" \
		--input-type "$file_type" \
		--output-type "$file_type" \
		--filename-override "$file" \
		--"$action" /dev/stdin; then
		echo "Error: SOPS $action failed for $file ($(sops_age_identity_source), config=$sops_config)" >&2
		exit 1
	fi
}

# Decrypt the contents of encrypted files in a repository
decrypt_repo() {
	local root_path
	root_path=$(git rev-parse --show-toplevel)
	cd "$root_path"

	local files_to_decrypt=()

	# check-attr -z --stdin outputs null-delimited records of (path, attr, value).
	while IFS= read -r -d '' path && IFS= read -r -d '' _attr && IFS= read -r -d '' value; do
		if [[ "$value" == "$git_filter_name" ]] && [[ -f "$path" ]] && is_encrypted "$path"; then
			files_to_decrypt+=("$path")
		fi
	done < <(cd "$root_path" && git ls-files -z | git check-attr -z --stdin filter 2>/dev/null)
	
	if [[ ${#files_to_decrypt[@]} -eq 0 ]]; then
		echo "No encrypted files found to decrypt"
		return
	fi
	
	echo "Decrypting ${#files_to_decrypt[@]} files..."
	
	# Do not use git rm/reset/checkout here. Git may run the clean filter to
	# compare the existing working-tree file before replacing it, and clean
	# intentionally rejects ciphertext to prevent accidental double encryption.
	# Decrypt to a temporary file first, then atomically replace the ciphertext.
	local file tmp file_type
	for file in "${files_to_decrypt[@]}"; do
		tmp=$(mktemp "$(dirname "$file")/.git-sops-decrypt.XXXXXXXXXX")
		trap 'rm -f "$tmp"' RETURN INT TERM

		# Preserve the tracked file's mode before replacing it. The temporary
		# file is overwritten only after SOPS has successfully decrypted input.
		cp -p -- "$file" "$tmp"
		file_type=$(get_file_type "$file")
		if ! secrets decrypt "$file" "$file_type" < "$file" > "$tmp"; then
			echo "Error: Failed to decrypt $file" >&2
			rm -f "$tmp"
			trap - RETURN INT TERM
			exit 1
		fi

		mv -f -- "$tmp" "$file"
		trap - RETURN INT TERM

		# Refresh the index stat data through the clean filter. Since this file
		# was decrypted from its checked-in ciphertext, clean reuses that same
		# blob and leaves the repository clean instead of merely stat-dirty.
		git add -- "$file"
	done
	
	echo "Successfully decrypted ${#files_to_decrypt[@]} files"
}

# Initialize repository with the smudge and clean filter.
# Re-running overwrites, so switching modes is just `init` or `-b init`.
init() {
	local flag=""
	local mode="auto"
	if $binary_mode; then
		flag=" -b"
		mode="binary"
	fi

	git config --local --replace-all "filter.${git_filter_name}.required" true
	git config --local --replace-all "filter.${git_filter_name}.smudge"   "$self_path$flag smudge '%f'"
	git config --local --replace-all "filter.${git_filter_name}.clean"    "$self_path$flag clean '%f'"
	# textconv gets the blob path as an argument (not stdin), and git does
	# NOT substitute %f for textconv — so we use a dedicated subcommand.
	git config --local --replace-all "diff.${git_filter_name}.textconv"   "$self_path$flag textconv"
	echo "Repository configured for sops ($mode mode)"

	if [[ -t 0 ]]; then
		read -rp "Decrypt existing encrypted files? [yes/no] " should_decrypt
		if [[ "$should_decrypt" == [Yy]* ]]; then
			decrypt_repo
		fi
	else
		echo "Non-interactive; skipping decrypt. Run '$self_path decrypt' manually."
	fi
}

# Detect which SOPS envelope a blob uses by sniffing its contents. Needed
# because textconv gets a git-created temp file whose name lacks the
# original extension, so we can't rely on get_file_type.
sniff_sops_type() {
	local blob="$1"
	if head -c 16 "$blob" 2>/dev/null | grep -q '^{[[:space:]]*"data"'; then
		echo "binary"
	elif grep -q '^sops:' "$blob" 2>/dev/null; then
		echo "yaml"
	elif grep -q '^sops_version=' "$blob" 2>/dev/null; then
		echo "dotenv"
	elif grep -q '"sops"[[:space:]]*:' "$blob" 2>/dev/null; then
		echo "json"
	else
		echo "binary"
	fi
}

# Render a blob for `git diff` textconv. Unlike clean/smudge, git passes
# the blob as a file-path argument (no %f substitution, empty stdin). By
# the time textconv runs, git has already applied the smudge filter to
# the blob for filter-enabled paths, so the file is usually plaintext —
# just emit it. If smudge wasn't applied (filter not configured locally),
# fall back to decrypting ourselves.
textconv() {
	local blob="$1"
	local type

	if [[ -z "$blob" || ! -f "$blob" ]]; then
		echo "Error: textconv requires a blob file path (got '$blob')" >&2
		exit 1
	fi

	if ! is_encrypted "$blob"; then
		cat "$blob"
		return
	fi

	if $binary_mode; then
		type=binary
	else
		type=$(sniff_sops_type "$blob")
	fi

	# No --output-type: for binary envelopes --output-type binary re-wraps
	# plaintext in {"data":"..."}; for yaml/json/dotenv, omitting keeps the
	# decrypted form in the same shape as the original plaintext.
	if ! sops --config "$sops_config" \
		--input-type "$type" \
		--decrypt "$blob"; then
		echo "Error: SOPS textconv decrypt failed (type=$type, config=$sops_config)" >&2
		exit 1
	fi
}

# Decrypt the file content during checkout (smudge filter)
smudge() {
	local file="$1"
	local file_type tmp

	if [[ -z "$file" ]]; then
		echo "Error: No file specified for smudge" >&2
		exit 1
	fi

	tmp=$(mktemp)
	trap 'rm -f "$tmp"' RETURN INT TERM
	cat > "$tmp"

	if ! is_encrypted "$tmp"; then
		cat "$tmp"
		rm -f "$tmp"
		trap - RETURN INT TERM
		return
	fi

	file_type=$(get_file_type "$file")
	secrets decrypt "$file" "$file_type" < "$tmp"

	rm -f "$tmp"
	trap - RETURN INT TERM

	echo "Decrypted: $file" >&2
}

# Encrypt the file content before staging (clean filter)
clean() {
	local file="$1"
	local file_type

	if [[ -z "$file" ]]; then
		echo "Error: No file specified for clean" >&2
		exit 1
	fi

	# CRYPT_FORCE=1 bypasses the short-circuit so reencrypt can re-emit
	# ciphertext with the current recipients/mode even when plaintext is unchanged.
	if [[ "$CRYPT_FORCE" != "1" ]] && ! is_changed "$file"; then
		git cat-file -p "HEAD:$file"
		return
	fi

	file_type=$(get_file_type "$file")
	secrets encrypt "$file" "$file_type"

	echo "Encrypted: $file" >&2
}

# Force re-run of the clean filter on every crypt-filtered file. Use this
# after switching modes (auto <-> binary) or rotating recipients in .sops.yaml
# so HEAD adopts the new format/keys. Sets CRYPT_FORCE=1 so clean() bypasses
# its is_changed short-circuit and actually re-encrypts unchanged files.
# Files should be currently decrypted in the working tree (the normal state).
reencrypt() {
	local files=()
	while IFS= read -r -d '' path && IFS= read -r -d '' _attr && IFS= read -r -d '' value; do
		if [[ "$value" == "$git_filter_name" ]] && [[ -f "$path" ]]; then
			# CRYPT_FORCE=1 bypasses is_changed, so nothing downstream
			# will catch a still-encrypted working-tree file — sops would
			# then try to encrypt ciphertext and corrupt the blob.
			if is_encrypted "$path"; then
				echo "Error: $path is still encrypted in the working tree." >&2
				echo "reencrypt requires plaintext. Run '$self_path decrypt' first." >&2
				exit 1
			fi
			files+=("$path")
		fi
	done < <(git ls-files -z | git check-attr -z --stdin filter 2>/dev/null)

	if [[ ${#files[@]} -eq 0 ]]; then
		echo "No crypt-filtered files found"
		return
	fi

	echo "Re-running clean filter on ${#files[@]} files via 'git add --renormalize'..."
	CRYPT_FORCE=1 git add --renormalize -- "${files[@]}"

	if git diff --cached --quiet; then
		echo "No changes staged (files already match current filter output)"
	else
		echo "Staged re-encryption. Review with 'git diff --cached' and commit when ready."
	fi
}

# Return the sorted age recipients from a SOPS binary envelope on stdin.
age_recipients() {
	jq -r '.sops.age[]?.recipient // empty' | sort -u
}

# Re-encrypt only crypt-filtered files whose checked-in SOPS recipients differ
# from what the current .sops.yaml would produce. This is useful after adding,
# removing, or changing age recipients without rotating every encrypted blob.
reencrypt_stale() {
	local check_only=false
	local pathspec=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--check|--dry-run)
				check_only=true
				shift
				;;
			--)
				shift
				pathspec+=("$@")
				break
				;;
			*)
				pathspec+=("$1")
				shift
				;;
		esac
	done

	if ! $binary_mode; then
		echo "Error: reencrypt-stale currently supports binary mode only; run with -b." >&2
		exit 1
	fi

	if ! command -v jq &> /dev/null; then
		echo "Not found: jq" >&2
		exit 1
	fi

	local stale=()
	local checked=0

	while IFS= read -r -d '' path && IFS= read -r -d '' _attr && IFS= read -r -d '' value; do
		if [[ "$value" != "$git_filter_name" || ! -f "$path" ]]; then
			continue
		fi

		if is_encrypted "$path"; then
			echo "Error: $path is still encrypted in the working tree." >&2
			echo "reencrypt-stale requires plaintext. Run '$self_path decrypt' first." >&2
			exit 1
		fi

		local current expected current_tmp expected_tmp file_type
		current_tmp=$(mktemp)
		expected_tmp=$(mktemp)
		trap 'rm -f "$current_tmp" "$expected_tmp"' RETURN INT TERM

		if ! git cat-file -p ":$path" > "$current_tmp" 2>/dev/null; then
			# New file not yet in the index: it needs a normal add, not a
			# recipient refresh.
			rm -f "$current_tmp" "$expected_tmp"
			trap - RETURN INT TERM
			continue
		fi

		file_type=$(get_file_type "$path")
		if ! secrets encrypt "$path" "$file_type" < "$path" > "$expected_tmp"; then
			rm -f "$current_tmp" "$expected_tmp"
			trap - RETURN INT TERM
			exit 1
		fi

		current=$(age_recipients < "$current_tmp")
		expected=$(age_recipients < "$expected_tmp")
		checked=$((checked + 1))

		if [[ "$current" != "$expected" ]]; then
			stale+=("$path")
			printf 'Needs re-encryption: %s\n' "$path"
		fi

		rm -f "$current_tmp" "$expected_tmp"
		trap - RETURN INT TERM
	done < <(
		if [[ ${#pathspec[@]} -gt 0 ]]; then
			git ls-files -z -- "${pathspec[@]}"
		else
			git ls-files -z
		fi | git check-attr -z --stdin filter 2>/dev/null
	)

	if [[ ${#stale[@]} -eq 0 ]]; then
		echo "No stale crypt-filtered files found ($checked checked)"
		return
	fi

	if $check_only; then
		echo "${#stale[@]} stale crypt-filtered files found ($checked checked)"
		return
	fi

	echo "Re-running clean filter on ${#stale[@]} stale files..."
	CRYPT_FORCE=1 git add --renormalize -- "${stale[@]}"
	echo "Staged stale re-encryption. Review with 'git diff --cached' and commit when ready."
}

if ! command -v sops &> /dev/null; then
	echo "Not found: sops"
	exit 1
fi

if [[ ! -f "$sops_config" ]]; then
	echo "Not found: $sops_config"
	exit 1
fi

if ! git rev-parse --is-inside-work-tree &> /dev/null; then
	echo "Error: Not inside a Git repository" >&2
	exit 1
fi

while [[ $# -gt 0 ]]; do
	case $1 in
		-b|--binary) binary_mode=true; shift ;;
		*) break ;;
	esac
done

case ${1:-} in
	init)      shift && init ;;
	smudge)    shift && smudge "$1" ;;
	clean)     shift && clean "$1" ;;
	textconv)  shift && textconv "$1" ;;
	decrypt)   shift && decrypt_repo ;;
	reencrypt) shift && reencrypt ;;
	reencrypt-stale) shift && reencrypt_stale "$@" ;;
	*) echo "Usage: $0 [-b|--binary] {init|smudge|clean|textconv|decrypt|reencrypt|reencrypt-stale [--check] [path ...]}" >&2; exit 2 ;;
esac
