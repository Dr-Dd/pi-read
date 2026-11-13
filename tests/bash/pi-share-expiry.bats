#!/usr/bin/env bats
# The expiry pi-share reports: unit_expiry itself, and the first stdout line end to end.

setup() {
	load sudo-sandbox
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
	STUB_DIR="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$STUB_DIR"
}

# fake_systemctl OUTPUT [RC]: a systemctl on PATH that logs its arguments, prints OUTPUT, exits RC.
fake_systemctl() {
	{
		echo '#!/bin/sh'
		echo "echo \"\$*\" >>${STUB_DIR}/calls"
		echo "printf '%s\n' '$1'"
		echo "exit ${2:-0}"
	} >"${STUB_DIR}/systemctl"
	chmod 0755 "${STUB_DIR}/systemctl"
}

@test "unit_expiry adds the duration to the unit's activation time" {
	fake_systemctl "@1700000000"
	run env PATH="$STUB_DIR:$PATH" bash -c 'source "$1" && unit_expiry pi-share-1000-abc 900 1699999999' _ "$PI_SHARE"
	[ "$status" -eq 0 ]
	[ "$output" = "1700000900" ]
	[ "$(cat "$STUB_DIR/calls")" = \
		"show --timestamp=unix --property=ActiveEnterTimestamp --value pi-share-1000-abc.service" ]
}

@test "unit_expiry falls back to the start time when systemctl fails" {
	fake_systemctl "" 1
	run env PATH="$STUB_DIR:$PATH" bash -c 'source "$1" && unit_expiry pi-share-x 900 1700000000' _ "$PI_SHARE"
	[ "$status" -eq 0 ]
	[ "$output" = "1700000900" ]
}

@test "unit_expiry falls back to the start time when systemctl prints something unparsable" {
	fake_systemctl "n/a"
	run env PATH="$STUB_DIR:$PATH" bash -c 'source "$1" && unit_expiry pi-share-x 60 1700000000' _ "$PI_SHARE"
	[ "$status" -eq 0 ]
	[ "$output" = "1700000060" ]
}

@test "sudo: the first output line is the expiry read from the cleanup unit's activation time" {
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "x"
		printf "@1700000000\n" >/mnt/stub/systemctl-show.out
		share --duration 90 -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		dir=$(share_dirs)
		id=${dir#/run/pi-share/}
		[ "$(printf "%s\n" "$out" | sed -n 1p)" = "expires"$'"'"'\t'"'"'"$((1700000000 + 90))" ]
		[ "$(printf "%s\n" "$out" | sed -n 2p)" = "/mnt/data/conf"$'"'"'\t'"'"'"$dir/mnt/data/conf" ]
		[[ $(stub_log systemctl) == *"show --timestamp=unix --property=ActiveEnterTimestamp --value pi-share-$id.service"* ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: without systemd's activation time the expiry counts from when pi-share started" {
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "x"
		stub_status systemctl-show 1
		before=$(date +%s)
		share --duration 900 -- /mnt/data/conf
		after=$(date +%s)
		[ "$rc" -eq 0 ]
		[[ $(printf "%s\n" "$out" | sed -n 1p) =~ ^expires$'"'"'\t'"'"'[0-9]+$ ]]
		expires=$(printf "%s\n" "$out" | sed -n 1p | cut -f2)
		[ "$expires" -ge $((before + 900)) ]
		[ "$expires" -le $((after + 900)) ]
		[ "$(printf "%s\n" "$out" | wc -l)" -eq 2 ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
