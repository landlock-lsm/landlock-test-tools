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

dmesg --console-level warn

echo 1 > /proc/sys/kernel/panic_on_oops
echo 1 > /proc/sys/kernel/panic_on_warn
echo 1 > /proc/sys/vm/panic_on_oom

echo -1 > /proc/sys/kernel/panic

exit_poweroff() {
	if [[ -n "${TEST_RET:-}" ]]; then
		echo "$1" > "${TEST_RET}"
	fi
	exec poweroff -f
}

if [[ -z "${TEST_UID:-}" ]]; then
	echo "ERROR: This must be launched by uml-run.sh" >&2
	exit_poweroff 1
fi

if [[ -z "${INVOCATION_ID:-}" ]]; then
	echo "ERROR: This must be launched by systemd" >&2
	exit_poweroff 1
fi

TEST_EXEC="$(< /proc/cmdline)"
TEST_EXEC="${TEST_EXEC#* --}"

if [[ -z "${TEST_EXEC}" ]]; then
	echo "ERROR: Missing command" >&2
	exit_poweroff 1
fi

if [[ "${HOME:-/}" == / ]]; then
	export HOME="$(getent passwd "${TEST_UID}" | cut -d: -f6)"
fi

if [[ -h /tmp ]]; then
	echo "ERROR: /tmp must not be a symlink" >&2
	exit_poweroff 1
fi
mount -t tmpfs -o "mode=1777,nosuid,nodev" tmpfs /tmp

if [[ -z "${TMPDIR:-}" ]]; then
	export TMPDIR="/tmp"
fi

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

cd "${TEST_CWD}"

# Keeps root's capabilities but switches to the current user.
CAPS="$(setpriv --dump | sed -n -e 's/^Capability bounding set: \(.*\)$/+\1/p' | sed -e 's/,/,+/g')"
CMD=(setpriv --inh-caps "${CAPS}" --ambient-caps "${CAPS}" --reuid "${TEST_UID}" -- ${TEST_EXEC})

echo "[*] Launching ${CMD[@]}"

RET=0
"${CMD[@]}" || RET=$?

echo "[*] Returned value: ${RET}"

exit_poweroff "${RET}"
