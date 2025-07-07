#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2015-2023 Mickaël Salaün <mic@digikod.net>
#
# Launch a minimal User-Mode Linux system to run all Landlock tests.
#
# Examples:
# ./uml-run.sh linux-6.1 -- bash -i
# ./uml-run.sh .../linux -- .../tools/testing/selftests/kselftest_install/run_kselftest.sh

set -e -u -o pipefail

if [[ $# -lt 3 ]]; then
	echo "usage: ${BASH_SOURCE[0]} <linux-uml-kernel> -- <exec-path> [exec-arg]..." >&2
	exit 1
fi

BASE_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

KERNEL="$1"
shift

if [[ "${1:-}" != "--" ]] then
	echo "ERROR: Missing '--' argument" >&2
	exit 1
fi
shift

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

KERNEL_DIR="$(dirname -- "${KERNEL}")/"
if [[ "${KERNEL_DIR}" =~ ^/(tmp|run)/ ]]; then
	echo "ERROR: The kernel must not be in /tmp nor /run: ${KERNEL_DIR}" >&2
	exit 1
fi

OUT_DIR="$(mktemp --directory --tmpdir uml-run-out.XXXXXXXXXX)"
OUT_RET="${OUT_DIR}/ret"

cleanup() {
	trap - QUIT INT TERM EXIT
	set +e +u

	local ret="$(< "${OUT_RET}")"
	rm -r -- "${OUT_DIR}"
	exit "${ret}"
}

trap cleanup QUIT INT TERM EXIT

echo "[*] Booting kernel ${KERNEL}"

"${KERNEL}" \
	"rootfstype=hostfs" \
	"rootflags=/" \
	"root=98:0" \
	"rw" \
	"console=tty0" \
	"mem=256M" \
	"quiet" \
	"SYSTEMD_UNIT_PATH=${BASE_DIR}/guest/systemd" \
	"PATH=${BASE_DIR}/guest:${PATH:-/usr/bin}" \
	"TERM=${TERM:-linux}" \
	"TEST_UID=$(id -u)" \
	"TEST_CWD=$(pwd)" \
	"TEST_RET=${OUT_RET}" \
	"TEST_EXEC=$(printf "%s" "$*" | base64 --wrap=0)"
