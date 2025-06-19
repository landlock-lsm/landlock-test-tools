#!/usr/bin/env bash
#
# Run all tests and exit with an error if any failed.
#
# Cf. kselftest/kselftest_install/run_kselftest.sh

set -e -u -o pipefail

pushd "$1"

COVERAGE_DIR="${2:-}"

while read f; do
	echo "[+] Running $f:"
	"./$f"

	if dmesg --notime --kernel | grep '^\(BUG\|WARNING\):'; then
		exit 1
	fi
done < <(ls -1 *_test | sort)

popd

if [[ -n "${COVERAGE_DIR}" ]]; then
	echo "[+] Gathering coverage"
	rm "${COVERAGE_DIR}/gcov.tar.gz" 2>/dev/null || :
	gcov_gather_on_test.sh "${COVERAGE_DIR}/gcov.tar.gz"
fi
