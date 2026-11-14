#!/usr/bin/env bats
# What the calling user controls must not steer pi-share: neither the PATH it is called with, nor
# a link the user made that shows one name on the approval screen and copies another file.

setup() {
	load sudo-sandbox
	require_sandbox
}

@test "sudo: commands on the caller's PATH never run as root" {
	# The sandbox sudoers sets no secure_path, so sudo hands pi-share the caller's PATH.
	run sandbox '
		make_file /mnt/data/conf "x" 0600
		install -d -o 1000 -g 1000 -m 0755 /mnt/evil
		for c in bash stat; do
			printf "%s\n" "#!/bin/sh" "echo $c >>/mnt/log/evil" "exec /usr/bin/$c \"\$@\"" >/mnt/evil/$c
			chmod 0755 /mnt/evil/$c
		done
		rc=0
		PATH=/mnt/evil:$PATH as_tester /mnt/bin/pi-share -- /mnt/data/conf >/mnt/log/out 2>/mnt/log/err || rc=$?
		cat /mnt/log/out /mnt/log/err
		[ "$rc" -eq 0 ]
		[ "$(wc -l </mnt/log/out)" -eq 2 ]
		[ ! -e /mnt/log/evil ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a link the user made to a root-only file" {
	run sandbox '
		make_file /mnt/data/root-only.conf "ROOT ONLY" 0600
		install -d -o 1000 -g 1000 -m 0755 /mnt/usertmp
		setpriv --reuid 1000 --regid 1000 --init-groups ln -s /mnt/data/root-only.conf /mnt/usertmp/debug.log
		share -- /mnt/usertmp/debug.log
		[ "$rc" -eq 1 ]
		[[ $err == *"refused (a link, or not a canonical path): /mnt/usertmp/debug.log; request /mnt/data/root-only.conf itself"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a path that is not canonical, naming the canonical one" {
	run sandbox '
		make_file /mnt/data/conf "x" 0600
		share -- /mnt/data/../data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"request /mnt/data/conf itself"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
