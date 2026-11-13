#!/usr/bin/env bats

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
}

@test "sourcing pi-share defines main without running it" {
	run bash -c 'source "$1" && declare -F main' _ "$PI_SHARE"
	[ "$status" -eq 0 ]
	[ "$output" = "main" ]
}

@test "running the skeleton fails" {
	run "$PI_SHARE"
	[ "$status" -ne 0 ]
}
