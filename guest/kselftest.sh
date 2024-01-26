#!/usr/bin/env bash
#
# Run all tests and exit with an error if any failed.
#
# Cf. kselftest/kselftest_install/run_kselftest.sh

set -e -u -o pipefail

cd "$1"

for f in *_test; do
	echo "[+] Running $f:"
	"./$f"
done
