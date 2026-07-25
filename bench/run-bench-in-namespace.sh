#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Must be executed insided a dedicated mount namespace.
#
# This setup is required to run the benchmarks in a namespace where the root is
# a tmpfs.  This avoids inconsistent results.
#
# Copyright © 2025 Mickaël Salaün <mic@digikod.net>.

set -u -e -o pipefail

mkdir_mount() {
	local d="$1"
	mkdir "/mnt$d"
	mount --rbind "$d" "/mnt$d"
}

if [[ -z "${IN_BENCHMARK_NS:-}" ]]; then
	echo "This command must be called in a dedicated mount namespace" >&2
	exit 1
fi

mount -t tmpfs tmp /mnt

mkdir_mount /usr
mkdir_mount /lib
mkdir_mount /lib64
mkdir_mount /bin
mkdir_mount /sys
mkdir_mount /proc

cp perf /mnt/
cp sandboxer /mnt/
cp open-ntimes /mnt/

mkdir /mnt/old

# We create the same number of dirs/files no matter what depth or number
# of rules we're testing with, to rule out inconsistency caused by
# non-Landlock factors.

mkdir -p /mnt/1/2/3/4/5/6/7/8/9/0/1/2/3/4/5/6/7/8/9/0/1/2/3/4/5/6/7/8/9
mkdir /mnt/extra_rules
for i in $(seq 1 1000); do
	touch "/mnt/extra_rules/_$i"
done
sync

cd /mnt
pivot_root . old
cd .

"$@"
