#!/usr/bin/env bash
# Run after scripts/download.sh; test only a disposable copy, without network access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/macmtp-download-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/scripts" "$FIXTURE/thirdparty/downloads"
cp "$ROOT/scripts/download.sh" "$FIXTURE/scripts/"
cp "$ROOT/thirdparty/dependencies.tsv" "$FIXTURE/thirdparty/"
cp "$ROOT/thirdparty/downloads/"*.tar.* "$FIXTURE/thirdparty/downloads/"
run() { bash "$FIXTURE/scripts/download.sh" "$@" > "$FIXTURE/result.log" 2>&1; }
fail() {
    if run "$@"; then echo 'Expected nonzero exit' >&2; exit 1; fi
}
run --offline
for name in libusb-1.0.29 libgpg-error-1.58 libgcrypt-1.11.2 libmtp-1.1.23; do
    test -f "$FIXTURE/thirdparty/sources/$name/configure"
done
echo 'PASS: offline extraction of all four pinned archives'
printf 'local source edit\n' > "$FIXTURE/thirdparty/sources/libusb-1.0.29/local-edit.txt"
run --offline
test -f "$FIXTURE/thirdparty/sources/libusb-1.0.29/local-edit.txt"
echo 'PASS: repeated download preserves local source edits'
run --offline --force
test ! -e "$FIXTURE/thirdparty/sources/libusb-1.0.29/local-edit.txt"
find "$FIXTURE/thirdparty/backups" -name local-edit.txt | grep -q .
echo 'PASS: force extraction backs up local edits'
rm "$FIXTURE/thirdparty/sources/libusb-1.0.29/.macmtp-source.sha256"
fail --offline
grep -q 'Existing source is not managed' "$FIXTURE/result.log"
echo 'PASS: unmanaged source is not overwritten'
run --offline --force
printf 'corruption\n' >> "$FIXTURE/thirdparty/downloads/libmtp-1.1.23.tar.gz"
fail --offline
grep -q 'SHA-256 mismatch' "$FIXTURE/result.log"
echo 'PASS: corrupt archive is rejected before extraction'
rm "$FIXTURE/thirdparty/downloads/libmtp-1.1.23.tar.gz"
fail --offline
grep -q 'Missing offline archive' "$FIXTURE/result.log"
echo 'PASS: missing offline archive returns failure'
fail --invalid-option
grep -q 'Unknown argument' "$FIXTURE/result.log"
echo 'PASS: invalid option returns failure'
echo 'DOWNLOAD TESTS PASS: 7 checks'
