#!/usr/bin/env bats
# pi-share run through the real sudo, as root of an unprivileged sandbox (see sudo-sandbox.bash).
# systemd and the sudoers rule are placeholders there.

setup() {
	load sudo-sandbox
	require_sandbox
}

@test "sudo: shares a root-only file with the exact output and the same content" {
	run sandbox '
		make_file /mnt/data/app/conf "secret value" 0600
		share -- /mnt/data/app/conf
		[ "$rc" -eq 0 ]
		[[ $(printf "%s\n" "$out" | sed -n 2p) =~ ^/mnt/data/app/conf$'"'"'\t'"'"'/run/pi-share/1000-[0-9a-f]{16}/mnt/data/app/conf$ ]]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "secret value" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: copy is tester-owned 0400, share tree tester-owned 0700, /run/pi-share root 0711" {
	run sandbox '
		make_file /mnt/data/app/conf "x" 0600
		share -- /mnt/data/app/conf
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(stat -c "%u:%g %a" "$copy")" = "1000:1000 400" ]
		dir=$(share_dirs)
		[ "$(find "$dir" -type d | wc -l)" -eq 4 ]
		[ -z "$(find "$dir" -type d \( ! -uid 1000 -o ! -gid 1000 -o ! -perm 0700 \))" ]
		[ "$(stat -c "%u:%g %a" /run/pi-share)" = "0:0 711" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: several files give one line each, in order, in the same share dir" {
	run sandbox '
		make_file /mnt/data/b "B"
		make_file /mnt/data/a "A"
		make_file /mnt/other/c "C"
		share -- /mnt/data/b /mnt/data/a /mnt/other/c
		[ "$rc" -eq 0 ]
		[ "$(printf "%s\n" "$out" | tail -n +2 | wc -l)" -eq 3 ]
		[ "$(printf "%s\n" "$out" | tail -n +2 | cut -f1 | tr "\n" " ")" = "/mnt/data/b /mnt/data/a /mnt/other/c " ]
		dir=$(share_dirs)
		[ "$(printf "%s\n" "$out" | tail -n +2 | cut -f2 | tr "\n" " ")" = "$dir/mnt/data/b $dir/mnt/data/a $dir/mnt/other/c " ]
		[ "$(cat "$dir/mnt/data/b" "$dir/mnt/data/a" "$dir/mnt/other/c" | tr -d "\n")" = "BAC" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a symlink is refused, naming the file it leads to" {
	run sandbox '
		make_file /mnt/data/real "R"
		mkdir -m 0755 /mnt/links
		ln -s /mnt/data/real /mnt/links/alias
		share -- /mnt/links/alias
		[ "$rc" -eq 1 ]
		[[ $err == *"refused (a link, or not a canonical path): /mnt/links/alias; request /mnt/data/real itself"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: starts the cleanup unit with the default 15m and sleep infinity" {
	run sandbox '
		make_file /mnt/data/conf "x"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		dir=$(share_dirs)
		id=${dir#/run/pi-share/}
		[ "$(stub_log systemd-run)" = "--quiet --collect --unit=pi-share-$id --property=RuntimeMaxSec=900 --property=ExecStopPost=/usr/bin/rm -rf --one-file-system -- $dir -- sleep infinity" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: --duration 90 sets RuntimeMaxSec=90; --pid watches that process" {
	run sandbox '
		make_file /mnt/data/conf "x"
		share --duration 90 -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[[ $(stub_log systemd-run) == *" --property=RuntimeMaxSec=90 "* ]]
		[[ $(stub_log systemd-run) == *" -- sleep infinity" ]]
		: >/mnt/log/systemd-run
		share --pid "$$" -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[[ $(stub_log systemd-run) == *" --property=RuntimeMaxSec=900 "* ]]
		[[ $(stub_log systemd-run) == *" -- tail --pid=$$ -f /dev/null" ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses /etc/shadow, creates nothing and starts no unit" {
	run sandbox '
		share -- /etc/shadow
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared"* ]]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a symlink in a tester-writable dir pointing at /etc/shadow" {
	run sandbox '
		mkdir -m 0755 /mnt/home
		install -d -o 1000 -g 1000 -m 0700 /mnt/home/tester
		ln -s /etc/shadow /mnt/home/tester/innocent
		share -- /mnt/home/tester/innocent
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a hard link to a never-share file" {
	run sandbox '
		make_file /mnt/secret/shadow "root:hash:::" 0600
		mount --bind /mnt/secret/shadow /etc/shadow
		mkdir -m 0755 /mnt/data
		ln /mnt/secret/shadow /mnt/data/harmless
		share -- /mnt/data/harmless
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared, linked"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a tester-owned file and a root file in a tester-writable dir" {
	run sandbox '
		make_file /mnt/data/mine "x" 0400 1000:1000
		share -- /mnt/data/mine
		[ "$rc" -eq 1 ]
		[[ $err == *"writable by you"* ]]
		[ -z "$out" ]
		install -d -o 1000 -g 1000 -m 0755 /mnt/userdir
		make_file /mnt/userdir/rootfile "x" 0600 0:0
		share -- /mnt/userdir/rootfile
		[ "$rc" -eq 1 ]
		[[ $err == *"writable by you"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: all or nothing: one valid and one refused file share nothing" {
	run sandbox '
		make_file /mnt/data/ok "x"
		share -- /mnt/data/ok /etc/shadow
		[ "$rc" -eq 1 ]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses files totalling over 50 MB" {
	run sandbox '
		mkdir -m 0755 /mnt/big
		truncate -s 30M /mnt/big/one /mnt/big/two
		chmod 0600 /mnt/big/one /mnt/big/two
		share -- /mnt/big/one /mnt/big/two
		[ "$rc" -eq 1 ]
		[[ $err == *"50 MB"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: systemd-run failing removes the share dir and prints nothing" {
	run sandbox '
		make_file /mnt/data/conf "x"
		stub_status systemd-run 1
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"could not start the cleanup service"* ]]
		[ -z "$out" ]
		[ -n "$(stub_log systemd-run)" ]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: cleanup unit not active after copying removes the share dir and prints nothing" {
	run sandbox '
		make_file /mnt/data/conf "x"
		stub_status systemctl-is-active 3
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"cleanup service stopped early"* ]]
		[ -z "$out" ]
		[[ $(stub_log systemctl) == "is-active --quiet pi-share-1000-"* ]]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: root invoking it through sudo is refused" {
	run sandbox '
		make_file /mnt/data/conf "x"
		rc=0
		sudo -n /mnt/bin/pi-share -- /mnt/data/conf >/mnt/log/out 2>/mnt/log/err || rc=$?
		cat /mnt/log/out /mnt/log/err
		[ "$rc" -eq 1 ]
		grep -q "non-root user" /mnt/log/err
		[ ! -s /mnt/log/out ]
		[ ! -e /run/pi-share ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: --duration 2h exits 2 and shares nothing" {
	run sandbox '
		make_file /mnt/data/conf "x"
		share --duration 2h -- /mnt/data/conf
		[ "$rc" -eq 2 ]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
