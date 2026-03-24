#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Set up capabilities, working directory, and user switch.
# Used by init.sh (exec mode) and --remote-cmd (console mode).
#
# With arguments: runs the command as a shell command line.
# Without arguments: drops to an interactive bash shell.

# Set HOME from passwd if not already set (console path skips init.sh).
if [[ "${HOME:-/}" == / ]]; then
	export HOME="$(getent passwd "${TEST_UID}" | cut -d: -f6)"
fi

# Set PATH from host (passed via kernel arg by x86-run.sh).
if [[ -n "${TEST_PATH:-}" ]]; then
	export PATH="${TEST_PATH}"
fi

if [[ -z "${TMPDIR:-}" ]]; then
	export TMPDIR="/tmp"
fi

cd "${TEST_CWD}"

# Keeps root's capabilities but switches to the current user.
CAPS="$(setpriv --dump | sed -n -e 's/^Capability bounding set: \(.*\)$/+\1/p' | sed -e 's/,/,+/g')"

if [[ $# -gt 0 ]]; then
	# Uses "bash -c" to interpret the command as a shell command line,
	# enabling compound commands (&&, ||, |, ;) and quoted arguments.
	# Ambient capabilities survive the extra bash execve because bash is
	# not setuid.
	exec setpriv --inh-caps "${CAPS}" --ambient-caps "${CAPS}" \
		--reuid "${TEST_UID}" -- bash -c "$*"
else
	# Re-enable echo (socat's pty option sets echo=0) and sync
	# terminal size from host dimensions passed via kernel args.
	stty echo cols "${TEST_COLS:-80}" rows "${TEST_LINES:-24}" 2>/dev/null
	exec setpriv --inh-caps "${CAPS}" --ambient-caps "${CAPS}" \
		--reuid "${TEST_UID}" -- bash
fi
