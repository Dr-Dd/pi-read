#!/usr/bin/env bats
# check_file refuses when it cannot examine a file, and the never-share entries added for
# runtime credentials, Wi-Fi secrets and pacman's keyring.

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
}

@test "is_denied refuses runtime credentials, Wi-Fi secrets and pacman's keyring" {
	local p
	for p in /run/credentials /run/credentials/getty@tty1.service/secret \
		/run/NetworkManager/system-connections/wifi.nmconnection \
		/etc/wpa_supplicant/wpa_supplicant.conf /etc/pacman.d/gnupg/secring.gpg; do
		run bash -c 'source "$1" && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 0 ]
	done
}

@test "is_denied accepts the neighbours of those entries" {
	local p
	for p in /run/systemd/resolve/resolv.conf /run/NetworkManager/resolv.conf \
		/etc/NetworkManager/NetworkManager.conf /etc/pacman.d/mirrorlist /etc/pacman.conf; do
		run bash -c 'source "$1" && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 1 ]
	done
}

@test "check_file refuses when it cannot read the file's identity or its size" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		source /mnt/bin/pi-share
		make_file /mnt/data/conf "x" 0600
		for format in "%d:%i" "%s"; do
			stat() {
				[[ $2 == "$format" ]] && return 1
				command stat "$@"
			}
			rc=0
			line=$(check_file /mnt/data/conf 1000 1000 "" 2>/mnt/log/err) || rc=$?
			[ "$rc" -eq 1 ]
			[ -z "$line" ]
			grep -q "cannot examine: /mnt/data/conf" /mnt/log/err
		done
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
