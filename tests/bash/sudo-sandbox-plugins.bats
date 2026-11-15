#!/usr/bin/env bats
# The sudo sandbox finds sudo's plugin directory wherever the distribution keeps it (Ubuntu:
# /usr/libexec/sudo, Arch: /usr/lib/sudo), and fails, never skips, when there is none.

setup() {
	load sudo-sandbox
	require_sandbox
}

@test "with SANDBOX_SUDO_PLUGIN_DIRS naming no directory that holds sudoers.so, sandbox fails with the no sudo plugin directory message naming those dirs, and the snippet never runs" {
	local none="$BATS_TEST_TMPDIR/none $BATS_TEST_TMPDIR/empty"
	mkdir -p "$BATS_TEST_TMPDIR/empty"
	SANDBOX_SUDO_PLUGIN_DIRS=$none run sandbox 'echo SNIPPET-RAN'
	[ "$status" -ne 0 ]
	[[ $output == *"sudo sandbox: no sudo plugin directory (sudoers.so) in: $none"* ]]
	[[ $output != *SNIPPET-RAN* ]]
}

@test "inside the sandbox, the plugin directory holding sudoers.so is a mount point (the root-owned copy), and its sudoers.so is owned by 0:0" {
	run sandbox '
		dir=""
		for cand in /usr/libexec/sudo /usr/lib/sudo; do
			if [[ -f $cand/sudoers.so ]]; then dir=$(realpath -e -- "$cand"); break; fi
		done
		[ -n "$dir" ]
		mountpoint -q "$dir"
		[ "$(stat -c %u:%g -- "$dir/sudoers.so")" = 0:0 ]
		echo SNIPPET-OK
	'
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *SNIPPET-OK* ]]
}
