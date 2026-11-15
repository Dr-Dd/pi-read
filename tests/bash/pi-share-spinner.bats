#!/usr/bin/env bats
# The spinner pi-share draws on the user's terminal once sudo has accepted the password. The
# terminal is a pty from script(1): its stdout is everything the terminal showed.

setup() {
	load sudo-sandbox
	require_sandbox
}

# The sandbox snippet helpers: tty_share runs pi-share as tester on a terminal (PREFIX goes before
# setpriv, REDIRECT after the command) and sets rc, out, err and tty (what the terminal showed);
# same_result normalizes the random share id and the expiry so two runs can be compared.
helpers='
tty_share() {
	local prefix=$1 redirect=$2 cmd
	shift 2
	cmd="$prefix setpriv --reuid 1000 --regid 1000 --init-groups -- sudo -n /mnt/bin/pi-share $* >/mnt/log/out 2>/mnt/log/err $redirect"
	rc=0
	script -qefc "$cmd" /dev/null </dev/null >/mnt/log/tty || rc=$?
	out=$(cat /mnt/log/out)
	err=$(cat /mnt/log/err)
	tty=$(cat /mnt/log/tty)
	printf "rc=%s\nstdout:\n%s\nstderr:\n%s\ntty:\n%q\n" "$rc" "$out" "$err" "$tty"
}
normalize() {
	printf "%s\n" "$1" | sed -e "s/1000-[0-9a-f]\{16\}/ID/" -e "s/^expires\t.*/expires/"
}
'

@test "sudo: on a terminal, a file share shows the copies spinner line, and the result matches a run without a terminal" {
	run sandbox "${helpers}"'
		make_file /mnt/data/conf "x" 0600
		tty_share "" "" -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[[ $tty == *"pi-read: password accepted, preparing the copies..."* ]]
		tty_out=$out tty_err=$err
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[ "$(normalize "$tty_out")" = "$(normalize "$out")" ]
		[ "$tty_err" = "$err" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: on a terminal, a listing shows the listings spinner line" {
	run sandbox "${helpers}"'
		make_file /mnt/data/conf "x" 0600
		tty_share "" "" --list -- /mnt/data
		[ "$rc" -eq 0 ]
		[[ $tty == *"pi-read: password accepted, preparing the listings..."* ]]
		[[ $tty != *"copies"* ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: on a terminal, the spinner line is cleared before pi-share exits" {
	run sandbox "${helpers}"'
		make_file /mnt/data/conf "x" 0600
		tty_share "" "" -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[[ $tty == *$'"'"'\r\e[K'"'"' ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: on a terminal, a refused file clears the spinner and is refused as before" {
	run sandbox "${helpers}"'
		tty_share "" "" -- /etc/shadow
		[ "$rc" -eq 1 ]
		[[ $err == *"refused (never shared)"* ]]
		[ -z "$out" ]
		[[ $tty == *"preparing the copies..."* ]]
		[[ $tty == *$'"'"'\r\e[K'"'"' ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: with stdin not a terminal (askpass case), nothing is written to the terminal" {
	run sandbox "${helpers}"'
		make_file /mnt/data/conf "x" 0600
		tty_share "" "</dev/null" -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		# script(1) itself may leave a NUL on the pty when its stdin ends; pi-share adds nothing.
		[[ $tty != *"pi-read"* && $tty != *$'"'"'\e'"'"'* ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: without a controlling terminal (setsid), pi-share shares normally with nothing on stderr" {
	run sandbox "${helpers}"'
		make_file /mnt/data/conf "x" 0600
		tty_share "setsid -w" "" -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[[ $(printf "%s\n" "$out" | sed -n 2p) == /mnt/data/conf$'"'"'\t'"'"'* ]]
		[ -z "$err" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: no spinner process is left once pi-share has exited" {
	run sandbox "${helpers}"'
		make_file /mnt/data/conf "x" 0600
		tty_share "" "" -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		tty_share "" "" -- /etc/shadow
		[ "$rc" -eq 1 ]
		# pi-share and its spinner run as "/bin/bash /mnt/bin/pi-share ..." (the snippet itself does not).
		[ -z "$(pgrep -f "^/bin/bash /mnt/bin/pi-share" || true)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
