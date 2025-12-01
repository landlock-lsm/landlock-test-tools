#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# cd linux
# ARCH=x86_64 .../check-linux.sh build_light
# # Run a VM with this new kernel
# .../microbench.sh --ssh vm0
#
# Copyright © 2025 Mickaël Salaün <mic@digikod.net>.
# Copyright © 2025 Tingmao Wang <m@maowtm.org>.

set -e -u -o pipefail

NUM_ITERATIONS="15000000"

DIRNAME="$(dirname -- "${BASH_SOURCE[0]}")"
BASENAME="$(basename -- "${BASH_SOURCE[0]}")"

RUN_ON_CPU=""
DO_BPFTRACE=0
SSH_HOST=""
VERBOSE=0
NB_TRIALS=3

DEPTHS_ARR=(0 10 29)
NB_EXTRA_RULES_ARR=(0 10 1000)

print_usage() {
	echo "Usage: ${BASENAME} [--cpu <cpu_number>] [--bpftrace] [--ssh <host>]"
	echo "  --cpu <cpu_number>   Run the benchmark on the specified CPU core."
	echo "                       (default: 0)"
	echo "  --bpftrace           Use bpftrace to measure Landlock overhead."
	echo "  --ssh <host>         Use SSH to run the benchmark on the specified host."
	echo "  --verbose            Enable verbose output."
	echo "  --trials             <number>"
	echo "      Number of trials for each test size (default: ${NB_TRIALS})."
	echo "      This is probably only necessary for hashtable benchmarks."
	echo "  --num-iterations <number>"
	echo "      Number of openat iterations per test (default: ${NUM_ITERATIONS})."
	echo "  --depths d1,d2,..."
	echo "      Comma-separated list of directory depths to test.  Max depth is 29."
	echo "  --extra-rules n1,n2,..."
	echo "      Comma-separated list of numbers of extra rules to test."
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--cpu)
			shift
			if [[ $# -eq 0 ]]; then
				print_usage
			fi
			RUN_ON_CPU="$1"
			shift
			;;
		--bpftrace)
			DO_BPFTRACE=1
			shift
			;;
		--ssh)
			shift
			if [[ $# -eq 0 ]]; then
				print_usage
			fi
			SSH_HOST="$1"
			shift
			;;
		--verbose)
			VERBOSE=1
			shift
			;;
		--trials)
			shift
			if [[ $# -eq 0 ]]; then
				print_usage
			fi
			NB_TRIALS="$1"
			shift
			;;
		--num-iterations)
			shift
			if [[ $# -eq 0 ]]; then
				print_usage
			fi
			NUM_ITERATIONS="$1"
			shift
			;;
		--depths)
			shift
			if [[ $# -eq 0 ]]; then
				print_usage
			fi
			IFS=',' read -r -a DEPTHS_ARR <<< "$1"
			shift
			if [[ ${#DEPTHS_ARR[@]} -eq 0 ]]; then
				print_usage
			fi
			for depth in "${DEPTHS_ARR[@]}"; do
				if ! [[ "$depth" =~ ^[0-9]+$ ]] || [[ "$depth" -lt 0 ]] || [[ "$depth" -gt 29 ]]; then
					echo "ERROR: Invalid depth: $depth" >&2
					print_usage
				fi
			done
			;;
		--extra-rules)
			shift
			if [[ $# -eq 0 ]]; then
				print_usage
			fi
			IFS=',' read -r -a NB_EXTRA_RULES_ARR <<< "$1"
			shift
			if [[ ${#NB_EXTRA_RULES_ARR[@]} -eq 0 ]]; then
				print_usage
			fi
			for nb_extra_rules in "${NB_EXTRA_RULES_ARR[@]}"; do
				if ! [[ "$nb_extra_rules" =~ ^[0-9]+$ ]] || [[ "$nb_extra_rules" -lt 0 ]]; then
					echo "ERROR: Invalid number of extra rules: $nb_extra_rules" >&2
					print_usage
				fi
			done
			;;
		*)
			print_usage
			;;
	esac
done

print_verbose() {
	if [[ $VERBOSE -eq 1 ]]; then
		echo "[#]" "$@" >&2
	fi
}

if [[ -z "$RUN_ON_CPU" ]]; then
	RUN_ON_CPU=0
fi

BUILD_DIR=".out-landlock_local-x86_64-gcc"

get_file() {
	local path="$1"
	local basename="./$(basename -- "${path}")"
	shift
	local ret

	if [[ -e "${basename}" ]]; then
		path="${basename}"
	elif [[ ! -e "${path}" ]]; then
		"$@"
		if [[ ! -e "${path}" ]]; then
			echo "ERROR: Missing file: ${path}" >&2
			return 1
		fi
	fi

	if [[ -n "${SSH_HOST}" ]]; then
		scp "${path}" "${SSH_HOST}:"
	elif [[ "${path}" != "${basename}" ]]; then
		cp -v "${path}" .
	fi
}

if [[ -n "${SSH_HOST}" ]]; then
	echo "[*] Installing required dependencies"
	ssh "${SSH_HOST}" "pacman --noconfirm -Sy llvm-libs capstone perl python"
fi

get_file "${DIRNAME}/open-ntimes" make -C "${DIRNAME}"
get_file "${DIRNAME}/run-bench-in-namespace.sh"
get_file "${BUILD_DIR}/samples/landlock/sandboxer"
get_file "tools/perf/perf" make -C "tools/perf"

print_test_setup_json() {
	local do_landlock="$1"
	local dir_depth="$2"
	local nb_extra_rules="$3"

	jq -nc \
		--arg do_landlock "$do_landlock" \
		--arg dir_depth "$dir_depth" \
		--arg nb_extra_rules "$nb_extra_rules" \
		'{
			landlock: ($do_landlock == "1"),
			dir_depth: ($dir_depth | tonumber),
			nb_extra_rules: ($nb_extra_rules | tonumber)
		}'
}

run_test() {
	local do_landlock="$1"
	local dir_depth="$2"
	local nb_extra_rules="$3"
	local maybe_sandboxer=()
	if [[ $do_landlock -eq 1 ]]; then
		maybe_sandboxer=("./sandboxer")
	fi
	local d="$(echo /1/2/3/4/5/6/7/8/9/0/1/2/3/4/5/6/7/8/9/0/1/2/3/4/5/6/7/8/9 | head -c $((dir_depth * 2 + 1)))"
	local LL_FS_RO=/
	local LL_FS_RW=/
	for i in $(seq 1 $nb_extra_rules); do
		LL_FS_RO+=":/extra_rules/_$i"
	done
	local expected_errno=0
	local maybe_ssh=()
	if [[ -n "${SSH_HOST}" ]]; then
		maybe_ssh=(ssh "$SSH_HOST" --)
	fi
	local cmd=(
		"${maybe_ssh[@]}"
		env LL_FS_RO="$LL_FS_RO" LL_FS_RW="$LL_FS_RW" IN_BENCHMARK_NS=1 VERBOSE=$VERBOSE unshare --mount --
		./run-bench-in-namespace.sh taskset -c "${RUN_ON_CPU}" "${maybe_sandboxer[@]}"
		./open-ntimes "$NUM_ITERATIONS" "$expected_errno" "$d"
	)

	print_test_setup_json "$do_landlock" "$dir_depth" "$nb_extra_rules"
	print_verbose "Running command: ${cmd[*]}"

	local bpftrace_pid=""
	if [[ $DO_BPFTRACE -ne 0 ]]; then
		local bpftrace_cmd=(
			bpftrace -f json landlock_overhead.bt $RUN_ON_CPU
		)
		print_verbose "Running command: ${bpftrace_cmd[*]}"
		"${maybe_ssh[@]}" "${bpftrace_cmd[@]}" &
		bpftrace_pid=$!
		sleep 1
	fi

	"${cmd[@]}"

	if [[ -n "$bpftrace_pid" ]]; then
		kill -INT $bpftrace_pid
		wait $bpftrace_pid
	fi
}

curr_count=0
total=$((NB_TRIALS * ${#DEPTHS_ARR[@]} * (1 + ${#NB_EXTRA_RULES_ARR[@]})))

print_progress() {
	local percent=$((curr_count * 100 / total))
	local msg="$1"
	if [[ $percent -lt 10 ]]; then
		percent=" $percent"
	fi
	echo "[ ${percent}%] $msg" >&2
}

for trial in $(seq 1 $NB_TRIALS); do
	for depth in "${DEPTHS_ARR[@]}"; do
		print_progress "Running trial $trial for no Landlock"
		run_test 0 $depth 0
		curr_count=$((curr_count + 1))
		for nb_extra_rules in "${NB_EXTRA_RULES_ARR[@]}"; do
			print_progress "Running trial $trial for depth $depth with $nb_extra_rules extra rules"
			run_test 1 $depth $nb_extra_rules
			curr_count=$((curr_count + 1))
		done
	done
done
