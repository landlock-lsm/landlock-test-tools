#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2015-2025 Mickaël Salaün <mic@digikod.net>
#
# Launch a minimal VM to run Landlock tests or an interactive console.
#
# With a command (exec mode):
# ./x86-run.sh .../arch/x86/boot/bzImage -c .../coverage_dir -- .../tools/testing/selftests/kselftest_install/run_kselftest.sh
# ./x86-run.sh .../arch/x86/boot/bzImage audit=1 -- .../test.sh
#
# Without a command (interactive console):
# ./x86-run.sh .../arch/x86/boot/bzImage
# Then connect from another terminal: vng --console-client

set -e -u -o pipefail

if [[ $# -lt 1 ]]; then
	echo "usage: ${BASH_SOURCE[0]} <linux-x86-kernel> [-c coverage_dir] [kernel-args...] [-- <exec-path> [exec-arg]...]" >&2
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

COVERAGE_DIR=""
if [[ "${1:-}" == "-c" ]]; then
	shift
	COVERAGE_DIR="${1:-}"
	if [[ -z "${COVERAGE_DIR}" || ! -d "${COVERAGE_DIR}" ]]; then
		echo "ERROR: Not a directory: ${COVERAGE_DIR}" >&2
		exit 1
	fi
	shift
fi

KERNEL_ARGS=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
	KERNEL_ARGS+=("$1")
	shift
done

INTERACTIVE=false
if [[ $# -eq 0 ]]; then
	INTERACTIVE=true
	set -- "echo '[+] Interactive console. Connect with: vng --console-client' && sleep infinity"
else
	shift
fi

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

ARGS=()
if [[ -n "${COVERAGE_DIR}" ]]; then
	ARGS+=(--rwdir "${COVERAGE_DIR}")
fi

for arg in "${KERNEL_ARGS[@]}"; do
	ARGS+=(--append "${arg}")
done

# Interactive console: keep the VM alive, console client gets a shell
# with the same capabilities, user, and working directory as exec mode.
if "${INTERACTIVE}"; then
	ARGS+=(--console --remote-cmd "${BASE_DIR}/guest/shell.sh")
	ARGS+=(--append "TEST_COLS=$(tput cols 2>/dev/null || echo 80)")
	ARGS+=(--append "TEST_LINES=$(tput lines 2>/dev/null || echo 24)")
fi

# Pass only the guest tools directory plus standard system directories as
# the guest PATH, not the full host PATH.  The kernel command line is bounded
# by CONFIG_COMMAND_LINE_SIZE (2048 on x86) and vng appends "init=" last, so a
# long PATH truncates "init=" and the guest panics before booting.  The guest
# runs on the host root over 9p, so the standard directories resolve to the
# host binaries (diod, bindfs, dmesg, setpriv, ...), and ${BASE_DIR}/guest
# provides the helper scripts (e.g. gcov_gather_on_test.sh).
GUEST_PATH="${BASE_DIR}/guest:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

vng --run "${KERNEL}" \
	--verbose \
	--user root \
	--rwdir "${OUT_DIR}" \
	"${ARGS[@]}" \
	--append "loglevel=4" \
	--append "TEST_PATH=${GUEST_PATH}" \
	--append "TERM=${TERM:-linux}" \
	--append "TEST_UID=$(id -u)" \
	--append "TEST_CWD=$(pwd)" \
	--append "TEST_RET=${OUT_RET}" \
	--append "TEST_EXEC=$(printf "%s" "$*" | base64 --wrap=0)" \
	"${BASE_DIR}/guest/init.sh"
