#!/usr/bin/env bash
# Download and extract pinned dependencies without compiling or overwriting local edits.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIRDPARTY="$PROJECT_ROOT/thirdparty"
OFFLINE=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --offline) OFFLINE=true ;;
        --force) FORCE=true ;;
        -h|--help) echo 'Usage: scripts/download.sh [--offline] [--force]'; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done
for tool in curl shasum tar mktemp; do command -v "$tool" >/dev/null; done
mkdir -p "$THIRDPARTY/downloads" "$THIRDPARTY/sources"
TEMP_FILE=""
TEMP_DIR=""
cleanup() {
    [[ -z "$TEMP_FILE" ]] || rm -f "$TEMP_FILE"
    [[ -z "$TEMP_DIR" ]] || rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
while IFS=$'\t' read -r name archive url expected; do
    [[ -n "$name" && "$name" != \#* ]] || continue
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ && "$archive" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ && "$url" == https://* && "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid dependency manifest' >&2; exit 1; }
    cached="$THIRDPARTY/downloads/$archive"
    if [[ ! -f "$cached" ]]; then
        if [[ "$OFFLINE" == true ]]; then echo "Missing offline archive: $archive" >&2; exit 1; fi
        TEMP_FILE="$(mktemp "$THIRDPARTY/downloads/.download.XXXXXX")"
        curl --fail --location --retry 2 --connect-timeout 20 --max-time 180 "$url" --output "$TEMP_FILE"
        actual="$(shasum -a 256 "$TEMP_FILE" | awk '{print $1}')"
        [[ "$actual" == "$expected" ]] || { echo "SHA-256 mismatch: $archive" >&2; exit 1; }
        mv "$TEMP_FILE" "$cached"
        TEMP_FILE=""
    fi
    actual="$(shasum -a 256 "$cached" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || { echo "SHA-256 mismatch: $archive" >&2; exit 1; }
    source_dir="$THIRDPARTY/sources/$name"
    if [[ -d "$source_dir" && "$FORCE" == false ]]; then
        [[ -f "$source_dir/.macmtp-source.sha256" && "$(cat "$source_dir/.macmtp-source.sha256")" == "$expected" ]] || {
            echo "Existing source is not managed by download.sh: $name; use --force to back it up and extract again" >&2; exit 1;
        }
        echo "SOURCE READY: $name (archive verified; existing source retained)"
        continue
    fi
    TEMP_DIR="$(mktemp -d "$THIRDPARTY/sources/.extract.XXXXXX")"
    tar -xf "$cached" -C "$TEMP_DIR"
    [[ -d "$TEMP_DIR/$name" && -f "$TEMP_DIR/$name/configure" ]] || { echo "Unexpected source layout: $archive" >&2; exit 1; }
    printf '%s\n' "$expected" > "$TEMP_DIR/$name/.macmtp-source.sha256"
    if [[ -e "$source_dir" ]]; then
        mkdir -p "$THIRDPARTY/backups"
        mv "$source_dir" "$THIRDPARTY/backups/$name.$(date +%s).$$"
    fi
    mv "$TEMP_DIR/$name" "$source_dir"
    rm -rf "$TEMP_DIR"
    TEMP_DIR=""
    echo "SOURCE READY: $name (SHA-256 verified)"
done < "$THIRDPARTY/dependencies.tsv"
echo 'DOWNLOAD PASS: all pinned dependencies available under thirdparty/'
