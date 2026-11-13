#!/usr/bin/env bats
# The never-share list beyond the original entries: old password hashes, TLS keys and other
# service secrets (see README.md, "Files that are never shared").

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
}

# Run a snippet with pi-share sourced.
in_script() {
	run bash -c 'source "$1" && shift && eval "$@"' _ "$PI_SHARE" "$@"
}

@test "is_denied refuses old password hashes and the added service secrets" {
	local p
	for p in /etc/security/opasswd /etc/security/opasswd- \
		/etc/ssl/private/server.key /etc/ssl/private \
		/etc/letsencrypt/archive/example.com/privkey1.pem \
		/etc/letsencrypt/live/example.com/privkey.pem \
		/etc/krb5.keytab /etc/ipsec.secrets \
		/etc/ppp/pap-secrets /etc/ppp/chap-secrets \
		/var/lib/samba/private/secrets.tdb /var/lib/sss/db/cache_implicit_files.ldb \
		/etc/libvirt/secrets/9f0e; do
		run bash -c 'source "$1" && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 0 ]
	done
}

@test "is_denied accepts the neighbours of the added secrets" {
	local p
	for p in /etc/security/limits.conf /etc/ssl/certs/ca-certificates.crt \
		/etc/letsencrypt/renewal/example.com.conf \
		/etc/ppp/options /etc/ppp/pap-secrets.example \
		/var/lib/samba/smb.conf /etc/libvirt/qemu/win.conf \
		/etc/ipsec.conf /etc/krb5.conf /var/lib/sssfoo; do
		run bash -c 'source "$1" && is_denied "$2"' _ "$PI_SHARE" "$p"
		[ "$status" -eq 1 ]
	done
}

@test "denied_scan_roots lists the added prefixes and skips the virtual trees" {
	in_script 'denied_scan_roots'
	[ "$status" -eq 0 ]
	local p
	for p in /etc/ssl/private /etc/letsencrypt/archive /etc/letsencrypt/live \
		/etc/krb5.keytab /etc/ipsec.secrets /var/lib/samba/private /var/lib/sss \
		/etc/libvirt/secrets; do
		grep -qxF -- "$p" <<<"$output"
	done
	for p in /proc /sys /dev /swapfile; do
		! grep -qxF -- "$p" <<<"$output"
	done
}

@test "sudo: refuses opasswd and a TLS key before creating anything" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		share -- /etc/security/opasswd
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared"* ]]
		[ -z "$out" ]
		share -- /etc/ssl/private/server.key
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared"* ]]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a hard link to a file under /etc/ssl/private" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		if [ -d /etc/ssl/private ]; then
			mount -t tmpfs -o mode=0700 tmpfs /etc/ssl/private
		else
			mount -t tmpfs -o mode=0755 tmpfs /etc/ssl
			mkdir -m 0700 /etc/ssl/private
		fi
		make_file /mnt/secret/key "PRIVATE KEY"
		make_file /etc/ssl/private/key "PRIVATE KEY"
		mount --bind /mnt/secret/key /etc/ssl/private/key
		mkdir -m 0755 /mnt/data
		ln /mnt/secret/key /mnt/data/harmless
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
