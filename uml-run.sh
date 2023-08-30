#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2015-2023 Mickaël Salaün <mic@digikod.net>
#
# Launch a minimal User-Mode Linux system to run all Landlock tests.
#
# Examples:
# ./uml-run.sh linux-6.1 bash HISTFILE=/dev/null
# ./uml-run.sh .../linux .../tools/testing/selftests/kselftest_install/run_kselftest.sh

set -e -u -o pipefail

if [[ $# -lt 2 ]]; then
	echo "usage: ${BASH_SOURCE[0]} <linux-uml-kernel> <exec-path> [VAR=value]..." >&2
	exit 1
fi

BASE_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

KERNEL="$1"
if ! EXEC="$(command -v -- "$2")"; then
	echo "ERROR: Failed to find command $2" >&2
	exit 1
fi

if [[ ! -x "${EXEC}" ]]; then
	echo "ERROR: Failed to find executable file ${EXEC}" >&2
	exit 1
fi

shift 2

# Looks first for a known kernel.
KERNEL_ARTIFACT="${BASE_DIR}/kernels/artifacts/${KERNEL}"
if [[ "${KERNEL}" == "$(basename -- "${KERNEL}")" ]] && [[ -f "${KERNEL_ARTIFACT}" ]]; then
	KERNEL="${KERNEL_ARTIFACT}"
fi

# Handles relative file without "./" prefix.
KERNEL="$(readlink -f -- "${KERNEL}")"

if [[ ! -f "${KERNEL}" ]]; then
	echo "ERROR: Could not find this kernel: ${KERNEL}" >&2
	exit 1
fi

OUT_RET="$(mktemp --tmpdir= uml-ret.XXXXXXXXXX)"

cleanup() {
	rm -- "${OUT_RET}"
}

trap cleanup QUIT INT TERM EXIT

echo "[*] Booting kernel ${KERNEL}"

"${KERNEL}" \
	"rootfstype=hostfs" \
	"rootflags=/" \
	"rw" \
	"quiet" \
	"systemd.unit=landlock-test.service" \
	"SYSTEMD_UNIT_PATH=${BASE_DIR}/guest" \
	"PATH=${BASE_DIR}/guest:${PATH:-/usr/bin}" \
	"UML_UID=$(id -u)" \
	"UML_CWD=$(pwd)" \
	"UML_EXEC=${EXEC}" \
	"UML_RET=${OUT_RET}" \
	"$@"

exit "$(< "${OUT_RET}")"
