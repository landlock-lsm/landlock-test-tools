#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2015-2025 Mickaël Salaün <mic@digikod.net>
#
# Launch a minimal VM to run all Landlock tests.
#
# This cannot be used to run an interactive shell yet (see SSH notes).
#
# Examples:
# ./x86-run.sh .../arch/x86/boot/bzImage -- .../tools/testing/selftests/kselftest_install/run_kselftest.sh

set -e -u -o pipefail

if [[ $# -lt 2 ]]; then
	echo "usage: ${BASH_SOURCE[0]} <linux-x86-kernel> -- <exec-path> [exec-arg]..." >&2
	exit 1
fi

BASE_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

# Handles relative file without "./" prefix.
KERNEL="$(readlink -f -- "$1")"
if [[ ! -f "${KERNEL}" ]]; then
	echo "ERROR: Could not find this kernel: ${KERNEL}" >&2
	exit 1
fi
shift


if [[ "${1:-}" != "--" ]] then
	echo "ERROR: Missing '--' argument" >&2
	exit 1
fi
shift

KERNEL_DIR="$(dirname -- "${KERNEL}")/"
if [[ "${KERNEL_DIR}" =~ ^/(tmp|run)/ ]]; then
	echo "ERROR: The kernel must not be in /tmp nor /run: ${KERNEL_DIR}" >&2
	exit 1
fi

if ! command -v vng &>/dev/null; then
	echo "ERROR: Unable to find the \"vng\" command (provided by virtme-ng)" >&2
	exit 1
fi

OUT_DIR="$(mktemp --directory --tmpdir x86-run-out.XXXXXXXXXX)"
OUT_RET="${OUT_DIR}/ret"
echo 1 > "${OUT_RET}"

cleanup() {
	local ret
	trap - QUIT INT TERM EXIT
	set +e +u

	ret="$(< "${OUT_RET}")"
	rm -r -- "${OUT_DIR}"
	exit "${ret}"
	exit 1
}

trap cleanup QUIT INT TERM EXIT

echo "[*] Booting kernel ${KERNEL}"

# # virtme-ng requires a ~/.ssh/id_*.pub file
# if [[ ! -e ~/.ssh/id_virtme-ng-landlock-test ]]; then
# 	ssh-keygen -f ~/.ssh/id_virtme-ng-landlock-test -N ''
# fi
# vng --ssh
# ssh -F ~/.cache/virtme-ng/.ssh/virtme-ng-ssh.conf -o IdentityFile=~/.ssh/id_virtme-ng-landlock-test -l root ssh://virtme-ng:2222

vng --run "${KERNEL}" \
	--verbose \
	--user root \
	--rwdir "${OUT_DIR}" \
	--append "loglevel=4" \
	--append "TEST_PATH=${BASE_DIR}/guest:${PATH:-/usr/bin}" \
	--append "TERM=${TERM:-linux}" \
	--append "TEST_UID=$(id -u)" \
	--append "TEST_CWD=$(pwd)" \
	--append "TEST_RET=${OUT_RET}" \
	--append "TEST_EXEC=$(printf "%s" "$*" | base64 --wrap=0)" \
	"${BASE_DIR}/guest/init.sh"
