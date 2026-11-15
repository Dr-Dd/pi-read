#!/usr/bin/env bats
# pi-share --probe, which the extension runs through `sudo -n` to learn whether sudo still
# remembers the password (see sudo-sandbox.bash).

setup() {
	load sudo-sandbox
	require_sandbox
}

@test "--probe prints the probe line and exits 0, creating nothing and starting no unit" {
	run sandbox '
		share --probe
		[ "$rc" -eq 0 ]
		[ "$out" = "pi-share: probe" ]
		[ -z "$err" ]
		[ ! -e /run/pi-share ]
		[ ! -s /mnt/log/systemd-run ]
		[ ! -s /mnt/log/gitleaks ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
