#!/usr/bin/env bash

# This script integrates the `sops` secrets management tool with Git, providing
# functionality to initialize repositories with a custom clean and smudge filter
# that enables automatic encryption and decryption of files defined for use with
# this filter in .gitattributes (e.g. `.env* filter=crypt`).

set -eo pipefail

if [ -z "$SOPS_AGE_KEY_FILE" ]; then
	export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
fi

if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
	echo "Error: Age key not found at $SOPS_AGE_KEY_FILE" >&2
	echo "On NixOS, this should be created by the system activation script." >&2
	exit 1
fi

self_path=$(readlink -f "$0")
sops_config=$(dirname $(realpath "$0"))/../.sops.yaml
update_keys=false

git_filter_name=crypt
encryption_marker="ENC[AES256"

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

# Check if the Git repository has already been initialized with the filter
is_initialized() {
	git config --get "filter.${git_filter_name}.required" &> /dev/null &&
	git config --get "filter.${git_filter_name}.smudge" &> /dev/null &&
	git config --get "filter.${git_filter_name}.clean" &> /dev/null &&
	git config --get "diff.${git_filter_name}.textconv" &> /dev/null
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
		# Compare the decrypted HEAD contents to the working file via streaming
		! cmp -s "$file" <(git cat-file -p "HEAD:$file" | secrets decrypt "$file" "$file_type")
	else
		# Compare the encrypted HEAD contents to the working file via streaming
		! cmp -s "$file" <(git cat-file -p "HEAD:$file")
	fi
}

# Determine file type for sops encryption
get_file_type() {
	# Currently using binary format to avoid revealing file structure
	echo "binary"
	
	# Uncomment the code below for proper file type detection:
	# local file="$1"
	# local extension="${file##*.}"
	# 
	# case "${extension,,}" in
	# 	json)
	# 		echo "json"
	# 		;;
	# 	yaml|yml)
	# 		echo "yaml"
	# 		;;
	# 	toml)
	# 		echo "toml"
	# 		;;
	# 	ini)
	# 		echo "ini"
	# 		;;
	# 	env)
	# 		echo "dotenv"
	# 		;;
	# 	xml)
	# 		echo "xml"
	# 		;;
	# 	csv)
	# 		echo "csv"
	# 		;;
	# 	*)
	# 		# For unknown extensions, try to detect by content
	# 		if [[ -f "$file" ]]; then
	# 			local first_line
	# 			first_line=$(head -n1 "$file" 2>/dev/null | tr -d '\n\r')
	# 			case "$first_line" in
	# 				'{'*|'['*)
	# 					echo "json"
	# 					;;
	# 				*':'*|'---'*)
	# 					echo "yaml"
	# 					;;
	# 				'['*']'*)
	# 					echo "ini"
	# 					;;
	# 				*)
	# 					echo "binary"
	# 					;;
	# 			esac
	# 		else
	# 			echo "binary"
	# 		fi
	# 		;;
	# esac
}

# Encrypt/decrypt file with sops with retry logic
secrets() {
	local action=$1
	local file=$2
	local file_type=$3
	local max_retries=3
	local retry_count=0

	if [[ "$action" != @(encrypt|decrypt) ]]; then
		echo "Error: Invalid action. Use 'encrypt' or 'decrypt'" >&2
		exit 1
	fi

	local sops_stderr

	while [[ $retry_count -lt $max_retries ]]; do
		sops_stderr=$(mktemp)
		if sops --config "$sops_config" \
			--input-type "$file_type" \
			--output-type "$file_type" \
			--filename-override "$file" \
			--"$action" /dev/stdin 2>"$sops_stderr"; then
			rm -f "$sops_stderr"
			return 0
		fi

		((retry_count++))
		if [[ $retry_count -lt $max_retries ]]; then
			echo "Warning: SOPS $action failed for $file, retrying ($retry_count/$max_retries)..." >&2
			cat "$sops_stderr" >&2
			rm -f "$sops_stderr"
			sleep 1
		fi
	done

	echo "Error: SOPS $action failed for $file after $max_retries attempts" >&2
	echo "SOPS error output:" >&2
	cat "$sops_stderr" >&2
	rm -f "$sops_stderr"
	echo "Debug info: SOPS_AGE_KEY_FILE=$SOPS_AGE_KEY_FILE, config=$sops_config" >&2
	exit 1
}

# Decrypt the contents of encrypted files in a repository
decrypt_repo() {
	local root_path=$(git rev-parse --show-toplevel)
	
	# Get files with crypt filter more efficiently with error handling
	local files_to_decrypt=()
	
	if ! command -v xargs >/dev/null 2>&1; then
		echo "Error: xargs command not found" >&2
		exit 1
	fi
	
	while IFS= read -r -d '' file; do
		if [[ -n "$file" ]] && [[ -f "$file" ]] && is_encrypted "$file"; then
			files_to_decrypt+=("$file")
		fi
	done < <(git ls-files -z "$root_path" | xargs -0 git check-attr --stdin filter 2>/dev/null | grep "filter: $git_filter_name" | cut -d ':' -f 1 | tr '\n' '\0')
	
	if [[ ${#files_to_decrypt[@]} -eq 0 ]]; then
		echo "No encrypted files found to decrypt"
		return
	fi
	
	echo "Decrypting ${#files_to_decrypt[@]} files..."
	
	# Process files in batches to avoid command line length limits
	local batch_size=50
	local total_batches=$(((${#files_to_decrypt[@]} + batch_size - 1) / batch_size))
	
	for ((i=0; i<${#files_to_decrypt[@]}; i+=batch_size)); do
		local batch=("${files_to_decrypt[@]:i:batch_size}")
		local batch_num=$((i/batch_size + 1))
		
		echo "Processing batch $batch_num/$total_batches (${#batch[@]} files)..."
		
		# Remove from cache and checkout with error handling
		if ! git -c "filter.${git_filter_name}.clean=cat" rm --cached --quiet "${batch[@]}" 2>/dev/null; then
			echo "Warning: Failed to remove some files from cache in batch $batch_num" >&2
		fi
		
		if ! git -c "filter.${git_filter_name}.clean=cat" checkout HEAD --quiet -- "${batch[@]}" 2>/dev/null; then
			echo "Error: Failed to checkout files in batch $batch_num" >&2
			exit 1
		fi
	done
	
	echo "Successfully decrypted ${#files_to_decrypt[@]} files"
}

# Initialize repository with the smudge and clean filter
init() {
	if is_initialized; then
		echo "Repository already initialized; skipping"
		return
	fi

	git config --local --replace-all "filter.${git_filter_name}.required" true
	git config --local --replace-all "filter.${git_filter_name}.smudge" "$self_path smudge '%f'"
	git config --local --replace-all "filter.${git_filter_name}.clean" "$self_path clean '%f'"
	git config --local --replace-all "diff.${git_filter_name}.textconv" "$self_path clean '%f'"
	echo "Repository initialized for use with sops"

	read -rp "Decrypt existing encrypted files? [yes/no] " should_decrypt
	if [[ "$should_decrypt" == [Yy]* ]]; then
		decrypt_repo
	fi
}

# Decrypt the file content during checkout (smudge filter)
smudge() {
	local file="$1"
	local file_type

	if [[ -z "$file" ]]; then
		echo "Error: No file specified for smudge" >&2
		exit 1
	fi

	file_type=$(get_file_type "$file")
	secrets decrypt "$file" "$file_type"

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

	if ! is_changed "$file"; then
		git cat-file -p "HEAD:$file" >&1
		return
	fi

	file_type=$(get_file_type "$file")
	secrets encrypt "$file" "$file_type"

	echo "Encrypted: $file" >&2
}

update() {
	local terminate=false
	local auto_commit=false
	
	# Check if .sops.yaml has changed
	if cmp -s "$sops_config" <(git cat-file -p "HEAD:.sops.yaml"); then
		echo "sops config is not changed, nothing to update"
		exit 0
	fi
	
	# If no files specified, discover all encrypted files automatically
	if [[ -z "$@" ]]; then
		echo "Discovering encrypted files..."
		local files_to_update=()
		
		# Find all files with crypt filter that are encrypted
		while IFS= read -r -d '' file; do
			if [[ -n "$file" ]] && [[ -f "$file" ]] && is_encrypted "$file"; then
				files_to_update+=("$file")
			fi
		done < <(git ls-files | git check-attr filter --stdin 2>/dev/null | grep "filter: $git_filter_name" | cut -d ':' -f 1 | tr '\n' '\0')
		
		if [[ ${#files_to_update[@]} -eq 0 ]]; then
			echo "No encrypted files found to update"
			exit 0
		fi
		
		echo "Found ${#files_to_update[@]} encrypted files to update"
		set -- "${files_to_update[@]}"
	fi
	
	# Process each file
	echo "Updating keys for encrypted files..."
	for i in "$@"; do
		if ! exists_in_head "$i"; then
			echo "Warning: File $i is not part of this repository, skipping" >&2
			continue
		elif is_changed "$i"; then
			echo "Warning: File $i has uncommitted changes, skipping" >&2
			continue
		else
			echo "Updating keys for: $i"
			if ! sops --config "$sops_config" updatekeys "$i"; then
				echo "Error: Failed to update keys for $i" >&2
				terminate=true
			else
				git add "$i"
			fi
		fi
	done
	
	if $terminate; then
		echo "Some files failed to update, aborting"
		exit 1
	fi
	
	# Check if there are staged changes
	if git diff --cached --quiet; then
		echo "No changes to commit"
		exit 0
	fi
	
	# Ask user about committing
	read -rp "Commit the key updates? [yes/no] " should_commit
	if [[ "$should_commit" == [Yy]* ]]; then
		git commit -m "Update sops keys"
		echo "Changes committed successfully"
	else
		echo "Changes staged but not committed. Use 'git commit' to commit manually."
	fi
	
	# Always decrypt repo after key updates
	echo "Decrypting repository with updated keys..."
	decrypt_repo
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

case $1 in
	init) shift && init ;;
	smudge) shift && smudge "$1" ;;
	clean) shift && clean "$1" ;;
	update) shift && update "$@" ;;
	decrypt) shift && decrypt_repo ;;
	*) echo "Usage: $0 {init|smudge|clean|update|decrypt}" >&2; exit 0 ;;
esac