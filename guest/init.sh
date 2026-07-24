#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2014-2025 Mickaël Salaün <mic@digikod.net>
#
# Init task for an User-Mode Linux kernel, designed to be launched by
# uml-run.sh
#
# Mount filesystems, set up networking and configure the current user just
# enough to run all Landlock tests.
#
# Required boot variables:
# - TEST_UID
# - TEST_CWD
#
# Optional boot variable:
# - TEST_RET

set -e -u -o pipefail



if [[ -z "${PATH:-}" ]]; then
	export PATH="/sbin:/bin:/usr/sbin:/usr/bin"
fi

exit_poweroff() {
	trap - QUIT INT TERM EXIT
	set +e

	if [[ -n "${TEST_RET:-}" ]]; then
		echo "$1" > "${TEST_RET}"
	fi
	exec poweroff -f
	exit 1
}

RET=1

cleanup() {
	exit_poweroff "${RET}"
}

trap cleanup QUIT INT TERM EXIT

dmesg --console-level warn

echo 1 > /proc/sys/kernel/panic_on_oops
echo 1 > /proc/sys/kernel/panic_on_warn
echo 1 > /proc/sys/vm/panic_on_oom

echo -1 > /proc/sys/kernel/panic

if [[ -z "${TEST_UID:-}" ]]; then
	echo "ERROR: This must be launched by uml-run.sh" >&2
	exit_poweroff 1
fi

if [[ -z "${TEST_EXEC:-}" ]]; then
	echo "ERROR: Missing command" >&2
	exit_poweroff 1
fi

if [[ -h /tmp ]]; then
	echo "ERROR: /tmp must not be a symlink" >&2
	exit_poweroff 1
fi

# TEST_RET may live under /tmp (mktemp's default when TMPDIR is unset or
# /tmp), which the tmpfs below then hides from the guest.  Open it now,
# while it is still visible on hostfs; after mounting the tmpfs, bind the
# open file (via /proc/self/fd) onto a fixed path there and report
# through that path.  The bind keeps the host inode reachable across the
# shadowing, and the descriptor is closed before the test runs so it
# cannot leak into it.
RET_FD=
if [[ -n "${TEST_RET:-}" ]]; then
	exec {RET_FD}>"${TEST_RET}"
fi

mount -t tmpfs -o "mode=1777,nosuid,nodev" tmpfs /tmp

if [[ -n "${RET_FD:-}" ]]; then
	: > /tmp/.ret
	mount --bind "/proc/self/fd/${RET_FD}" /tmp/.ret
	exec {RET_FD}>&-
	TEST_RET=/tmp/.ret
fi

if [[ -z "${TMPDIR:-}" ]]; then
	export TMPDIR="/tmp"
fi

mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true

if [[ ! -d /mnt ]]; then
	mkdir /mnt
fi
mount -t tmpfs -o "mode=755,nosuid,nodev" tmpfs /mnt

if command -v diod >/dev/null; then
	mkdir /mnt/test-v9fs-src
	chmod 1777 /mnt/test-v9fs-src
	mkdir /mnt/test-v9fs
	# Listen on the 9pfs port.
	diod -n -l 127.0.0.1:564 -e /mnt/test-v9fs-src
	mount.diod -n 127.0.0.1:/mnt/test-v9fs-src /mnt/test-v9fs
else
	echo "WARNING: Could not find the diod command." >&2
fi

if command -v bindfs >/dev/null; then
	mkdir /mnt/test-fuse-src
	chmod 1777 /mnt/test-fuse-src
	mkdir /mnt/test-fuse
	bindfs /mnt/test-fuse-src /mnt/test-fuse
else
	echo "WARNING: Could not find the bindfs command." >&2
fi

DECODED_EXEC="$(printf "%s" "${TEST_EXEC}" | base64 -d)"
SHELL_SH="$(dirname -- "${BASH_SOURCE[0]}")/shell.sh"

echo "[*] Launching ${SHELL_SH} ${DECODED_EXEC}"

RET=0
"${SHELL_SH}" "${DECODED_EXEC}" || RET=$?

echo "[*] Returned value: ${RET}"
