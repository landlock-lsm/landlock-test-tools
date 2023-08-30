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

# Quickly run cargo test to get the built binary.
EXEC="$(${CARGO} test --no-run --color never 2>&1 | sed -n 's,^ *Executable unittests src/lib.rs (\(.*\)) *$,\1,p')"

if [[ -z "${EXEC}" ]]; then
	echo "ERROR: Failed to get the test binary" >&2
	exit 1
fi

timeout --signal KILL 9 "${BASE_DIR}/uml-run.sh" \
	"${KERNEL}" \
	"${EXEC}" \
	"LANDLOCK_CRATE_TEST_ABI=${ABI}"
