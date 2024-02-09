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
	exec poweroff -f
}

if [[ -z "${UML_UID:-}" ]]; then
	echo "ERROR: This must be launched by uml-run.sh" >&2
	exit_poweroff 1
fi

if [[ -z "${SYSTEMD_EXEC_PID:-}" ]]; then
	echo "ERROR: This must be launched by systemd" >&2
	exit_poweroff 1
fi

UML_EXEC="$(< /proc/cmdline)"
UML_EXEC="${UML_EXEC#* --}"

if [[ -z "${UML_EXEC}" ]]; then
	echo "ERROR: Missing command" >&2
	exit_poweroff 1
fi

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

cd "${UML_CWD}"

# Keeps root's capabilities but switches to the current user.
CMD=(setpriv --inh-caps +all --ambient-caps +all --reuid "${UML_UID}" -- ${UML_EXEC})

echo "[*] Launching ${CMD[@]}"

RET=0
"${CMD[@]}" || RET=$?

echo "[*] Returned value: ${RET}"

exit_poweroff "${RET}"
