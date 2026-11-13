#!/usr/bin/env bats
# The never-share identities are collected once per run and passed to check_file, not recomputed
# per file (see denied_identities/check_file in bin/pi-share).

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
}

# Run a snippet with pi-share sourced.
in_script() {
	run bash -c 'source "$1" && shift && eval "$@"' _ "$PI_SHARE" "$@"
}

@test "is_denied_identity matches the only line of the list" {
	in_script 'is_denied_identity "10:20" "10:20"'
	[ "$status" -eq 0 ]
}

@test "is_denied_identity matches a line in the middle of the list" {
	in_script 'is_denied_identity "3:30" "$(printf "1:10\n3:30\n5:50\n")"'
	[ "$status" -eq 0 ]
}

@test "is_denied_identity rejects a missing identity and a prefix of a listed one" {
	local identity
	for identity in "10:2" "2:20" "x"; do
		run bash -c 'source "$1" && is_denied_identity "$2" "$(printf "10:20\n30:40\n")"' _ \
			"$PI_SHARE" "$identity"
		[ "$status" -eq 1 ]
	done
}

@test "is_denied_identity rejects any identity against an empty list" {
	local identity
	for identity in "10:20" ""; do
		run bash -c 'source "$1" && is_denied_identity "$2" ""' _ "$PI_SHARE" "$identity"
		[ "$status" -eq 1 ]
	done
}

@test "check_file uses the denied list it is given, for refusal and for acceptance" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		source /mnt/bin/pi-share
		make_file /mnt/data/conf "x" 0600
		identity=$(stat -c "%d:%i" -- /mnt/data/conf)
		rc=0
		err=$(check_file /mnt/data/conf 1000 1000 "$identity" 2>&1 >/dev/null) || rc=$?
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared, linked"* ]]
		rc=0
		err=$(check_file /mnt/data/conf 1000 1000 "$(printf "1:1\n%s\n2:2\n" "$identity")" 2>&1 >/dev/null) || rc=$?
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared, linked"* ]]
		rc=0
		line=$(check_file /mnt/data/conf 1000 1000 "$(printf "1:1\n2:2\n")" 2>/dev/null) || rc=$?
		[ "$rc" -eq 0 ]
		[ "$line" = "$(printf "/mnt/data/conf\t2")" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "check_file never calls denied_identities itself" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		source /mnt/bin/pi-share
		make_file /mnt/data/conf "x" 0600
		denied_identities() {
			echo "denied_identities was called" >&2
			return 1
		}
		rc=0
		err=$(check_file /mnt/data/conf 1000 1000 "" 2>&1 >/dev/null) || rc=$?
		[ "$rc" -eq 0 ]
		[ -z "$err" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "main collects the denied identities once for several files" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		source /mnt/bin/pi-share
		make_file /mnt/data/a "A" 0600
		make_file /mnt/data/b "B" 0600
		calls=/mnt/log/denied-calls
		: >"$calls"
		denied_identities() {
			echo call >>"$calls"
			printf "999999:999999\n"
		}
		export SUDO_UID=1000 SUDO_GID=1000
		main -- /mnt/data/a /mnt/data/b >/mnt/log/out
		[ "$(wc -l <"$calls")" -eq 1 ]
		[ "$(tail -n +2 /mnt/log/out | cut -f1 | tr "\n" " ")" = "/mnt/data/a /mnt/data/b " ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
