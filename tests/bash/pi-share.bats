#!/usr/bin/env bats

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
}

# Run a snippet with pi-share sourced.
in_script() {
	run bash -c 'source "$1" && shift && eval "$@"' _ "$PI_SHARE" "$@"
}

@test "sourcing pi-share defines main without running it" {
	run bash -c 'source "$1" && declare -F main' _ "$PI_SHARE"
	[ "$status" -eq 0 ]
	[ "$output" = "main" ]
}

@test "no arguments: exit 2 with usage" {
	run "$PI_SHARE"
	[ "$status" -eq 2 ]
	[[ $output == *usage:* ]]
}

@test "not running as root: refuses" {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	run "$PI_SHARE" -- /etc/hostname
	[ "$status" -eq 1 ]
	[[ $output == *"must run as root"* ]]
}

@test "parse_duration converts 90, 90s, 15m, 1h" {
	in_script 'echo "$(parse_duration 90) $(parse_duration 90s) $(parse_duration 15m) $(parse_duration 1h)"'
	[ "$status" -eq 0 ]
	[ "$output" = "90 90 900 3600" ]
}

@test "parse_duration rejects 0, -5, abc, 1d, 1.5h and empty" {
	local d
	for d in 0 -5 abc 1d 1.5h ""; do
		run bash -c 'source "$1" && parse_duration "$2"' _ "$PI_SHARE" "$d"
		[ "$status" -ne 0 ]
	done
}

@test "parse_duration rejects over the 1h maximum" {
	local d
	for d in 61m 3601; do
		run bash -c 'source "$1" && parse_duration "$2"' _ "$PI_SHARE" "$d"
		[ "$status" -ne 0 ]
	done
}

@test "is_denied refuses never-share paths" {
	local p
	for p in /etc/shadow /etc/shadow- /etc/gshadow /etc/ssh/ssh_host_ed25519_key \
		/root/x /proc/1/environ /sys/kernel /dev/sda /var/lib/docker/x; do
		run bash -c 'source "$1" && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 0 ]
	done
}

@test "is_denied accepts ordinary files" {
	local p
	for p in /etc/hostname /etc/ssh/sshd_config /etc/ssh/ssh_host_ed25519_key.pub; do
		run bash -c 'source "$1" && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 1 ]
	done
}

@test "is_denied does not match lookalike prefixes" {
	local p
	for p in /rootfoo /devices/x /procfs; do
		run bash -c 'source "$1" && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 1 ]
	done
}

@test "validate_pid rejects non-numeric and dead PIDs" {
	run bash -c 'source "$1" && validate_pid abc' _ "$PI_SHARE"
	[ "$status" -ne 0 ]
	run bash -c 'source "$1" && validate_pid 99999999' _ "$PI_SHARE"
	[ "$status" -ne 0 ]
}

@test "validate_path rejects a relative path" {
	run bash -c 'source "$1" && validate_path etc/hostname' _ "$PI_SHARE"
	[ "$status" -ne 0 ]
}

@test "no chown, and setfacl only after the copy loop" {
	run bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -n "chown"' _ "$PI_SHARE"
	[ "$status" -eq 1 ]
	local copy_line grant_line
	copy_line=$(grep -n 'if ! copy_files' "$PI_SHARE" | cut -d: -f1)
	grant_line=$(grep -n 'if ! grant_read' "$PI_SHARE" | tail -1 | cut -d: -f1)
	[ -n "$grant_line" ]
	[ "$grant_line" -gt "$copy_line" ]
	[ "$(grep -v "^[[:space:]]*#" "$PI_SHARE" | grep -c "setfacl")" -eq 1 ]
}
