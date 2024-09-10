#!/usr/bin/env bash
#
# Run all tests and exit with an error if any failed.
#
# Cf. kselftest/kselftest_install/run_kselftest.sh

set -e -u -o pipefail

cd "$1"

while read f; do
	echo "[+] Running $f:"
	"./$f"

	if dmesg --notime --kernel | grep '^\(BUG\|WARNING\):'; then
		exit 1
	fi
done < <(ls -1 *_test | sort)
