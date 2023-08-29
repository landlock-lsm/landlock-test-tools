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
# - UML_EXEC
#
# Optional boot variable:
# - UML_RET

set -e -u -o pipefail

if [[ $$ -ne 1 ]]; then
	echo "ERROR: This must be run as the initial process" >&2
	exit 1
fi

echo "[*] Mounting filesystems"
mount -t proc proc /proc
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mkdir /dev/pts
mount -t devpts devpts /dev/pts
mount -t sysfs sysfs /sys
mount -t cgroup2 cgroup2 /sys/fs/cgroup

echo "[*] Configuring network"
ip address add 127.0.0.1/8 dev lo

if [[ -z "${PATH:-}" ]]; then
	export PATH="/sbin:/bin:/usr/sbin:/usr/bin"
fi

if [[ "${HOME:-/}" == / ]]; then
	export HOME="$(getent passwd "${UML_UID}" | cut -d: -f6)"
fi

if [[ -z "${TMPDIR:-}" ]]; then
	export TMPDIR="/tmp"
fi

cd "${UML_CWD}"

# Keeps root's capabilities but switches to the current user.
CMD=(setpriv --inh-caps +all --ambient-caps +all --reuid "${UML_UID}" -- "${UML_EXEC}")

echo "[*] Launching ${CMD[@]}"

RET=0
"${CMD[@]}" || RET=$?

echo "[*] Returned value: ${RET}"

if [[ -n "${UML_RET:-}" ]]; then
	echo ${RET} > "${UML_RET}"
fi

exec poweroff -f
