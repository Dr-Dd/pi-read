#!/usr/bin/env bats
# The share tree stays root's: the user reads the copies through an ACL entry and cannot change
# them or add files to /run. Run through the real sudo in the sandbox (see sudo-sandbox.bash).

setup() {
	load sudo-sandbox
	require_sandbox
}

# In the snippets: `tester CMD...` runs CMD as tester (uid/gid 1000) without sudo; `fails CMD...`
# fails the test when CMD succeeds (errexit ignores a plain `! CMD`); `copy` prints the copy path of
# the first requested file.
SNIPPET_HELPERS='
	tester() { setpriv --reuid 1000 --regid 1000 --init-groups -- "$@"; }
	fails() { if "$@"; then echo "unexpectedly succeeded: $*" >&2; return 1; fi; }
	copy() { printf "%s\n" "$out" | sed -n 2p | cut -f2; }
'

@test "sudo: the share dir and every dir under it are root-owned 0711, and nothing in it is tester-owned" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/app/conf "x"
		make_file /mnt/other/b "y"
		share -- /mnt/data/app/conf /mnt/other/b
		[ "$rc" -eq 0 ]
		dir=$(share_dirs)
		[ "$(find "$dir" -type d | wc -l)" -eq 5 ]
		[ -z "$(find "$dir" -type d \( ! -uid 0 -o ! -gid 0 -o ! -perm 0711 \))" ]
		[ -z "$(find "$dir" \( -uid 1000 -o -gid 1000 \))" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a copy carries exactly user::r, user:1000:r, group::---, mask::r, other::--- and tester can read it" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/app/conf "secret value"
		share -- /mnt/data/app/conf
		[ "$rc" -eq 0 ]
		[ "$(getfacl -cpn "$(copy)")" = "user::r--
user:1000:r--
group::---
mask::r--
other::---" ]
		[ "$(tester cat "$(copy)")" = "secret value" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: tester cannot create a file in the share dir or in a dir below it" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/app/conf "x"
		share -- /mnt/data/app/conf
		[ "$rc" -eq 0 ]
		dir=$(share_dirs)
		fails tester touch "$dir/new"
		fails tester touch "$dir/mnt/data/app/new"
		fails tester mkdir "$dir/mnt/newdir"
		[ "$(find "$dir" -type f | wc -l)" -eq 1 ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: tester cannot chmod, write to, remove or rename a copy" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/app/conf "x"
		share -- /mnt/data/app/conf
		[ "$rc" -eq 0 ]
		c=$(copy)
		fails tester chmod 0600 "$c"
		fails tester sh -c "echo more >>\"\$1\"" _ "$c"
		fails tester rm -f "$c"
		fails tester mv "$c" "$c.moved"
		[ "$(cat "$c")" = "x" ]
		[ "$(stat -c "%u:%g %a" "$c")" = "0:0 440" ]
		[ ! -e "$c.moved" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a listing is root-owned with the same ACL and tester can read it" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/a "A"
		share --list -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(stat -c "%u:%g %a" "$(copy)")" = "0:0 440" ]
		[ "$(getfacl -cpn "$(copy)")" = "user::r--
user:1000:r--
group::---
mask::r--
other::---" ]
		[ "$(tester head -n 1 "$(copy)")" = "# pi-share listing of /mnt/data, depth 1" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a setfacl that fails removes the share dir, prints nothing on stdout and stops the unit" {
	run sandbox "$SNIPPET_HELPERS"'
		printf "%s\n" "#!/bin/sh" "exit 1" >/mnt/stub/setfacl
		install -o 0 -g 0 -m 0755 -- /mnt/stub/setfacl /usr/local/bin/setfacl
		make_file /mnt/data/app/conf "x"
		share -- /mnt/data/app/conf
		[ "$rc" -ne 0 ]
		[ -z "$out" ]
		[[ $err == *"could not give you read access to the copies; nothing shared"* ]]
		[ -z "$(share_dirs)" ]
		[[ $(stub_log systemctl) == *"stop pi-share-1000-"* ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: the cleanup unit's ExecStopPost command, run as root, removes the whole share dir" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/app/conf "x"
		share -- /mnt/data/app/conf
		[ "$rc" -eq 0 ]
		dir=$(share_dirs)
		cmd=$(stub_log systemd-run)
		cmd=${cmd#*--property=ExecStopPost=}
		cmd=${cmd% -- sleep infinity}
		[ "$cmd" = "/usr/bin/rm -rf --one-file-system -- $dir" ]
		$cmd
		[ ! -e "$dir" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
