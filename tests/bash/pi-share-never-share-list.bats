#!/usr/bin/env bats
# The never-share list lives in a root-owned file (/usr/local/etc/pi-read/never-share.list), read
# by pi-share on every run; the repo ships its defaults in never-share.defaults.

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
	DEFAULTS="$BATS_TEST_DIRNAME/../../never-share.defaults"
}

# parse FILE: run parse_never_share FILE with pi-share sourced.
parse() {
	run bash -c 'source "$1" && parse_never_share "$2"' _ "$PI_SHARE" "$1"
}

@test "parse_never_share skips comments and blank lines, trims whitespace, CR and trailing slashes" {
	printf '# comment\n\n   \n  # indented comment\n  /a/b  \n/c/d/\r\n\t/e f//\n/g' >"$BATS_TEST_TMPDIR/list"
	parse "$BATS_TEST_TMPDIR/list"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '/a/b\n/c/d\n/e f\n/g')" ]
}

@test "parse_never_share rejects a relative entry, naming the line number" {
	printf '# comment\n/ok\netc/shadow\n' >"$BATS_TEST_TMPDIR/list"
	parse "$BATS_TEST_TMPDIR/list"
	[ "$status" -eq 1 ]
	[[ $output == *"line 3"* ]]
	[[ $output == *"not an absolute path: etc/shadow"* ]]
}

@test "parse_never_share rejects an entry with a control character" {
	printf '/ok\n/bad\033name\n' >"$BATS_TEST_TMPDIR/list"
	parse "$BATS_TEST_TMPDIR/list"
	[ "$status" -eq 1 ]
	[[ $output == *"line 2"* ]]
	[[ $output == *"control character"* ]]
}

@test "parse_never_share rejects a list with no entries" {
	printf '# only comments\n\n   \n' >"$BATS_TEST_TMPDIR/list"
	parse "$BATS_TEST_TMPDIR/list"
	[ "$status" -eq 1 ]
	[[ $output == *"no entries"* ]]
}

@test "is_denied applies a glob entry to the matching path and everything below it, not to lookalikes" {
	local p
	for p in /srv/keys/secret /srv/kv/secret /srv/keys/secret/x /srv/keys/deep/secret; do
		run bash -c 'source "$1" && DENIED_ENTRIES=("/srv/k*/secret") && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 0 ]
	done
	for p in /srv/keys/secrets /srv/other/secret /srv/keys; do
		run bash -c 'source "$1" && DENIED_ENTRIES=("/srv/k*/secret") && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 1 ]
	done
}

@test "is_denied refuses /proc, /sys and /dev even with an empty list" {
	local p
	for p in /proc /proc/1/environ /sys/kernel /dev/sda; do
		run bash -c 'source "$1" && DENIED_ENTRIES=() && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 0 ]
	done
	run bash -c 'source "$1" && DENIED_ENTRIES=() && is_denied /etc/shadow' _ "$PI_SHARE"
	[ "$status" -eq 1 ]
}

@test "the shipped defaults hold every former prefix and pattern" {
	parse "$DEFAULTS"
	[ "$status" -eq 0 ]
	output=$(sort <<<"$output")
	local expected
	expected=$(printf '%s\n' /etc/shadow'*' /etc/gshadow'*' /etc/security/opasswd'*' \
		/etc/ssh/ssh_host_'*'_key /etc/ppp/'*'-secrets \
		/root /etc/credstore /etc/credstore.encrypted /etc/cryptsetup-keys.d \
		/var/lib/systemd/credential.secret /run/credentials /etc/pacman.d/gnupg \
		/etc/ssl/private /etc/letsencrypt/archive /etc/letsencrypt/live /etc/krb5.keytab \
		/etc/ipsec.secrets /var/lib/samba/private /var/lib/sss /etc/libvirt/secrets \
		/etc/wireguard /etc/NetworkManager/system-connections \
		/run/NetworkManager/system-connections /etc/wpa_supplicant /var/lib/iwd \
		/var/lib/bluetooth /var/lib/systemd/coredump /swapfile /var/lib/docker | sort)
	[ "$output" = "$expected" ]
}

@test "sudo: a file under an entry added to the installed list is refused; without the entry it is shared" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "CONF"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		echo "/mnt/data" >>/usr/local/etc/pi-read/never-share.list
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared"* ]]
		[ -z "$out" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a hard link to a file matching a glob entry is refused as linked" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		echo "/mnt/secret/*.key" >>/usr/local/etc/pi-read/never-share.list
		make_file /mnt/secret/a.key "PRIVATE KEY"
		mkdir -m 0755 /mnt/data
		ln /mnt/secret/a.key /mnt/data/harmless
		share -- /mnt/data/harmless
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared, linked"* ]]
		[ -z "$out" ]
		# * crosses / for the hard-link check too, as it does for is_denied.
		make_file /mnt/secret/deep/b.key "PRIVATE KEY"
		ln /mnt/secret/deep/b.key /mnt/data/other
		share -- /mnt/data/other
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared, linked"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a missing installed list refuses everything, creating nothing and starting no unit" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "CONF"
		rm /usr/local/etc/pi-read/never-share.list
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"never-share list is missing"* ]]
		[[ $err == *"nothing shared"* ]]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: an installed list owned by the tester, writable by the tester, or in a tester-writable dir is refused" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		list=/usr/local/etc/pi-read/never-share.list
		make_file /mnt/data/conf "CONF"
		chown 1000:1000 "$list"
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"not owned by root"* ]]
		chown 0:0 "$list"
		chmod 0666 "$list"
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"writable by you: $list ($list)"* ]]
		chmod 0644 "$list"
		chmod 0777 /usr/local/etc/pi-read
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"writable by you: $list (/usr/local/etc/pi-read)"* ]]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: an installed list that is a symlink is refused" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		cd /usr/local/etc/pi-read
		mv never-share.list real.list
		ln -s real.list never-share.list
		make_file /mnt/data/conf "CONF"
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"not a regular file"* ]]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a malformed installed list is refused, naming the line" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		printf "/root\nrelative/entry\n" >/usr/local/etc/pi-read/never-share.list
		make_file /mnt/data/conf "CONF"
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"line 2: not an absolute path: relative/entry"* ]]
		[[ $err == *"nothing shared"* ]]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
