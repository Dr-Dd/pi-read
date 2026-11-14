#!/usr/bin/env bats
# The minimum gitleaks version: 8.21.3 is the first with --report-template, which pi-share runs.

setup() {
	REPO="$BATS_TEST_DIRNAME/../.."
}

@test "README.md and pi-share's not-found message both name gitleaks 8.21.3, and neither names 8.19" {
	grep -q 'gitleaks/gitleaks) 8\.21\.3 or newer' "$REPO/README.md"
	# Not `! grep`: errexit ignores a negated command, so that line could never fail the test.
	run grep -q '8\.19' "$REPO/README.md"
	[ "$status" -eq 1 ]
	run bash -c 'source "$1" && PATH=/nonexistent require_gitleaks gitleaks' _ "$REPO/bin/pi-share"
	[ "$status" -eq 1 ]
	[[ $output == *"install gitleaks (8.21.3 or newer, root-owned)"* ]]
	[[ $output != *"8.19"* ]]
}
