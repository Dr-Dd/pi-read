#!/usr/bin/env bats
# install.sh needs setfacl: pi-share gives the user read access to the copies through an ACL.

setup() {
	INSTALL="$BATS_TEST_DIRNAME/../../install.sh"
	STUBS="$BATS_TEST_TMPDIR/stubs"
	LOG="$BATS_TEST_TMPDIR/log"
	mkdir -p "$STUBS"
	: >"$LOG"
	export LOG
	local cmd
	for cmd in pi sudo visudo systemctl systemd-run gitleaks; do
		printf '%s\n' '#!/bin/sh' 'echo "$(basename "$0") $*" >>"$LOG"' >"$STUBS/$cmd"
		chmod +x "$STUBS/$cmd"
	done
}

@test "install: a missing setfacl fails before anything runs, naming it" {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	local cmd
	for cmd in dirname uname basename sh; do
		ln -s "$(command -v "$cmd")" "$STUBS/$cmd"
	done
	run env PATH="$STUBS" "$BASH" "$INSTALL"
	[ "$status" -eq 1 ]
	[[ $output == *"required command not found: setfacl"* ]]
	[ ! -s "$LOG" ]
}
