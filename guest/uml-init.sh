#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2014-2023 Mickaël Salaün <mic@digikod.net>
#
# Init task for an User-Mode Linux kernel, designed to be launched by
# uml-run.sh
#
# Mount filesystems, set up networking and configure the current user just
# enough to run all Landlock tests.
#
# Required boot variables:
# - UML_UID
# - UML_CWD
#
# Optional boot variable:
# - UML_RET

set -e -u -o pipefail

exit_poweroff() {
	if [[ -n "${UML_RET:-}" ]]; then
		echo "$1" > "${UML_RET}"
	fi
	exec /usr/sbin/poweroff -f
}

if [[ -z "${UML_UID:-}" ]]; then
	echo "ERROR: This must be launched by uml-run.sh" >&2
	exit_poweroff 1
fi

# Setup usually done by an actual init system (we use bash directly because
# we just want to run a single commandline, and this avoids adding a
# dependency on a given init system on the host filesystem)
mount -t proc proc /proc
ln -s /proc/self/fd/ /dev/fd

if [[ -z "${PATH:-}" ]]; then
	export PATH="/sbin:/bin:/usr/sbin:/usr/bin"
fi

if [[ "${HOME:-/}" == / ]]; then
	export HOME="$(getent passwd "${UML_UID}" | cut -d: -f6)"
fi

if [[ -h /tmp ]]; then
	echo "ERROR: /tmp must not be a symlink" >&2
	exit_poweroff 1
fi
mount -t tmpfs -o "mode=1777,nosuid,nodev" tmpfs /tmp

if [[ -z "${TMPDIR:-}" ]]; then
	export TMPDIR="/tmp"
fi

dmesg --console-level warn

echo 1 > /proc/sys/kernel/panic_on_oops
echo 1 > /proc/sys/kernel/panic_on_warn
echo 1 > /proc/sys/vm/panic_on_oom

echo -1 > /proc/sys/kernel/panic

cd "${UML_CWD}"

# Keeps root's capabilities but switches to the current user.
CAPS="$(setpriv --dump | sed -n -e 's/^Capability bounding set: \(.*\)$/+\1/p' | sed -e 's/,/,+/g')"
CMD=(setpriv --inh-caps "${CAPS}" --ambient-caps "${CAPS}" --reuid "${UML_UID}" -- "$@")

echo "[*] Launching ${CMD[@]}"

RET=0
"${CMD[@]}" || RET=$?

echo "[*] Returned value: ${RET}"

exit_poweroff "${RET}"
