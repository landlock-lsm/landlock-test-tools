#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2023 Microsoft Corporation
#
# Example: CARGO="rustup run stable cargo" ./test-rust.sh linux-6.1 2

set -e -u -o pipefail

if [[ $# -ne 2 ]]; then
	echo "usage: ${BASH_SOURCE[0]} <linux-uml-kernel> <landlock-abi>" >&2
	exit 1
fi

KERNEL="$1"
ABI="$2"

# Enables to use rustup.
if [[ -z "${CARGO:-}" ]]; then
	CARGO="cargo"
fi

BASE_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

${CARGO} test --no-run

# Quickly run cargo test to get the built binaries: the unit tests
# (src/lib.rs) and every integration test target (tests/*.rs).
EXECS="$(${CARGO} test --no-run --color never 2>&1 | sed -n 's,^ *Executable [^(]*(\([^)]*\)) *$,\1,p')"

if [[ -z "${EXECS}" ]]; then
	echo "ERROR: Failed to get the test binaries" >&2
	exit 1
fi

TIMEOUT=9

# Each test binary gets its own kernel boot so that a binary which
# sandboxes itself (or panics) cannot affect the next one.
while read -r EXEC; do
	echo "[*] Running ${EXEC}"
	timeout --signal KILL "${TIMEOUT}" </dev/null 2>&1 "${BASE_DIR}/uml-run.sh" \
		"${KERNEL}" \
		"LANDLOCK_CRATE_TEST_ABI=${ABI}" \
		-- \
		"${EXEC}" \
		| timeout "$((TIMEOUT + 1))" cat
done <<< "${EXECS}"
