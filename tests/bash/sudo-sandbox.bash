# shellcheck shell=bash
# Sandbox for running bin/pi-share through the real sudo binary, without touching the host.
#
# `sandbox SNIPPET` starts an unprivileged user + mount + pid namespace (unshare --map-auto
# --map-root-user), where the test is root, and inside it:
#   - mounts a root-owned 0755 tmpfs on /mnt that holds every sandbox file;
#   - bind-mounts a setuid-root copy of sudo over /usr/bin/sudo and a root-owned copy of its
#     plugins over /usr/lib/sudo;
#   - bind-mounts sandbox /etc/passwd, /etc/group, /etc/sudoers, /etc/sudo.conf and
#     /etc/pam.d/sudo (pam_permit: no password) and an empty /etc/sudoers.d;
#   - mounts a fresh tmpfs on /run, so /run/pi-share starts out absent;
#   - mount -t tmpfs on /usr/local with a root-owned gitleaks stub at /usr/local/bin/gitleaks: it
#     logs each call and the names in the directory it is given, prints /mnt/stub/gitleaks.out with
#     "@SCAN@" replaced by that directory, prints /mnt/stub/gitleaks.err to stderr, and exits with
#     /mnt/stub/gitleaks.rc, else 3 when it printed something and 0 when it did not;
#   - bind-mounts placeholder stubs over /usr/bin/systemd-run and /usr/bin/systemctl;
#   - installs pi-share root-owned 0755 at /mnt/bin/pi-share;
#   - mounts a tmpfs on /usr/local/etc and installs the repo's never-share.defaults root-owned 0644
#     at /usr/local/etc/pi-read/never-share.list, where pi-share reads the never-share list.
# Then it evaluates SNIPPET as sandbox root with errexit on, so a failing `[ ... ]` fails the test
# (the failing command is printed). Everything disappears with the namespace.
#
# Functions available to SNIPPET:
#   as_tester CMD...       run CMD as user tester (uid/gid 1000) through `sudo -n`
#   share ARGS...          run `sudo -n /mnt/bin/pi-share ARGS...` as tester; sets rc, out, err
#   make_file PATH TEXT [MODE] [OWNER]   create a file (parents root-owned 0755)
#   stub_status NAME RC    make a stub exit RC: NAME is systemd-run, systemctl-is-active,
#                          systemctl-show or gitleaks; systemctl-show prints
#                          /mnt/stub/systemctl-show.out
#   share_dirs             print the share dirs under /run/pi-share (one per line)
#   stub_log NAME          print what a stub logged: its arguments (one call per line) or, for
#                          gitleaks-scan, the names in each directory it was given

SANDBOX_HELPER=${BASH_SOURCE[0]}
readonly TESTER_UID=1000

# require_sandbox: fail (not skip) with a reason when this machine cannot build the sandbox.
require_sandbox() {
	if ! unshare --map-auto --map-root-user --mount --pid --fork --mount-proc true 2>/dev/null; then
		echo "sudo sandbox unavailable: needs unprivileged user namespaces, newuidmap/newgidmap" \
			"and a subuid/subgid range for $(id -un)" >&2
		return 1
	fi
}

# sandbox SNIPPET: run SNIPPET as root of a fresh sandbox (see the top of this file).
sandbox() {
	local pi_share
	# shellcheck disable=SC2154 # set by bats
	pi_share=$(realpath -e -- "${BATS_TEST_DIRNAME}/../../bin/pi-share")
	# shellcheck disable=SC2016 # expanded by the inner bash
	unshare --map-auto --map-root-user --mount --pid --fork --mount-proc \
		bash -c 'set -e; source "$1"; sandbox_setup "$2"; sandbox_eval "$3"' _ \
		"${SANDBOX_HELPER}" "${pi_share}" "$1"
}

sandbox_setup() {
	local pi_share=$1 s=/mnt f defaults
	set -e
	mount -t tmpfs -o mode=0755 tmpfs "${s}"
	mkdir -p "${s}/sudo-lib" "${s}/etc" "${s}/bin" "${s}/stub" "${s}/log"
	chmod 0755 "${s}/sudo-lib" "${s}/etc" "${s}/bin" "${s}/stub"
	chmod 0777 "${s}/log"

	# Real sudo, setuid root inside the namespace; sudo wants its plugins root-owned.
	cp /usr/bin/sudo "${s}/sudo"
	chown 0:0 "${s}/sudo"
	chmod 4755 "${s}/sudo"
	cp -a /usr/lib/sudo/. "${s}/sudo-lib/"
	chown -R 0:0 "${s}/sudo-lib"
	mount --bind "${s}/sudo" /usr/bin/sudo
	mount --bind "${s}/sudo-lib" /usr/lib/sudo

	install -o 0 -g 0 -m 0755 -- "${pi_share}" "${s}/bin/pi-share"
	defaults=$(dirname -- "${pi_share}")/../never-share.defaults
	# One tmpfs over all of /usr/local, first: the gitleaks stub goes in /usr/local/bin and the
	# never-share list in /usr/local/etc, each in its own mount inside it.
	mount -t tmpfs -o mode=0755 tmpfs /usr/local
	mkdir -m 0755 /usr/local/bin /usr/local/etc
	mount -t tmpfs -o mode=0755 tmpfs /usr/local/etc
	install -d -o 0 -g 0 -m 0755 -- /usr/local/etc/pi-read
	install -o 0 -g 0 -m 0644 -- "${defaults}" /usr/local/etc/pi-read/never-share.list

	printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' \
		"tester:x:${TESTER_UID}:${TESTER_UID}:tester:/mnt:/bin/bash" >"${s}/etc/passwd"
	printf '%s\n' 'root:x:0:' "tester:x:${TESTER_UID}:" >"${s}/etc/group"
	# Stands in for the sudoers rule install.sh adds, with pi-share at its sandbox path.
	cat >"${s}/etc/sudoers" <<-'EOF'
		# Sandbox placeholder for the pi-share rule from install.sh.
		Defaults !lecture
		Defaults!/mnt/bin/pi-share timestamp_timeout=0
		root ALL=(ALL:ALL) NOPASSWD: ALL
		tester ALL=(root) NOPASSWD: /mnt/bin/pi-share
	EOF
	chmod 0440 "${s}/etc/sudoers"
	: >"${s}/etc/sudo.conf"
	printf '%s\n' 'auth sufficient pam_permit.so' 'account sufficient pam_permit.so' \
		'session sufficient pam_permit.so' >"${s}/etc/pam-sudo"
	for f in passwd group sudoers sudo.conf; do
		mount --bind "${s}/etc/${f}" "/etc/${f}"
	done
	mount --bind "${s}/etc/pam-sudo" /etc/pam.d/sudo
	mount -t tmpfs -o mode=0755 tmpfs /etc/sudoers.d
	mount -t tmpfs -o mode=0755 tmpfs /run

	# PLACEHOLDER for systemd (none in the sandbox): log the call, exit with the chosen status.
	# `show` prints /mnt/stub/systemctl-show.out when a test provides one (the unit's timestamps).
	cat >"${s}/stub/systemd-run" <<-'EOF'
		#!/bin/sh
		echo "$*" >>/mnt/log/systemd-run
		exit "$(cat /mnt/stub/systemd-run.rc 2>/dev/null || echo 0)"
	EOF
	cat >"${s}/stub/systemctl" <<-'EOF'
		#!/bin/sh
		echo "$*" >>/mnt/log/systemctl
		if [ "$1" = is-active ]; then
			exit "$(cat /mnt/stub/systemctl-is-active.rc 2>/dev/null || echo 0)"
		fi
		if [ "$1" = show ]; then
			cat /mnt/stub/systemctl-show.out 2>/dev/null || true
			exit "$(cat /mnt/stub/systemctl-show.rc 2>/dev/null || echo 0)"
		fi
		exit 0
	EOF
	chmod 0755 "${s}/stub/systemd-run" "${s}/stub/systemctl"
	mount --bind "${s}/stub/systemd-run" /usr/bin/systemd-run
	mount --bind "${s}/stub/systemctl" /usr/bin/systemctl

	# PLACEHOLDER for gitleaks (the sandbox has none). It reports what the test described in
	# /mnt/stub/gitleaks.out, so a test can put a finding on any line of a staged copy.
	cat >"${s}/stub/gitleaks" <<-'EOF'
		#!/bin/sh
		echo "$*" >>/mnt/log/gitleaks
		for target in "$@"; do :; done
		ls -1A -- "$target" 2>/dev/null >>/mnt/log/gitleaks-scan
		if [ -s /mnt/stub/gitleaks.out ]; then
			sed "s|@SCAN@|$target|g" /mnt/stub/gitleaks.out
		fi
		if [ -s /mnt/stub/gitleaks.err ]; then
			cat /mnt/stub/gitleaks.err >&2
		fi
		rc=0
		if [ -f /mnt/stub/gitleaks.rc ]; then
			rc=$(cat /mnt/stub/gitleaks.rc)
		elif [ -s /mnt/stub/gitleaks.out ]; then
			rc=3
		fi
		exit "$rc"
	EOF
	chmod 0755 "${s}/stub/gitleaks"
	# A gitleaks the host has in a system directory would be found by pi-share too: mask it with an
	# empty file that is not executable, so the stub is the only gitleaks there is in here.
	local mask dir masked=""
	for dir in /usr/sbin /usr/bin /sbin /bin; do
		[ -f "${dir}/gitleaks" ] || continue
		mask=$(realpath -e -- "${dir}/gitleaks") || continue
		[[ ${masked} == *":${mask}:"* ]] && continue
		masked="${masked}:${mask}:"
		install -o 0 -g 0 -m 0644 -- /dev/null "${s}/stub/empty"
		mount --bind "${s}/stub/empty" "${mask}"
	done
	install -o 0 -g 0 -m 0755 -- "${s}/stub/gitleaks" /usr/local/bin/gitleaks
	set +e
}

sandbox_eval() {
	set -eE
	trap 'echo "FAILED: ${BASH_COMMAND}" >&2' ERR
	eval "$1"
}

as_tester() {
	setpriv --reuid "${TESTER_UID}" --regid "${TESTER_UID}" --init-groups -- sudo -n "$@"
}

share() {
	rc=0
	as_tester /mnt/bin/pi-share "$@" >/mnt/log/out 2>/mnt/log/err || rc=$?
	out=$(cat /mnt/log/out)
	err=$(cat /mnt/log/err)
	printf 'pi-share rc=%s\nstdout:\n%s\nstderr:\n%s\n' "${rc}" "${out}" "${err}"
}

make_file() {
	local path=$1 text=$2 mode=${3:-0600} owner=${4:-0:0}
	(umask 022 && mkdir -p -- "$(dirname -- "${path}")")
	printf '%s\n' "${text}" >"${path}"
	chown "${owner}" -- "${path}"
	chmod "${mode}" -- "${path}"
}

stub_status() {
	echo "$2" >"/mnt/stub/$1.rc"
}

share_dirs() {
	if [[ -d /run/pi-share ]]; then
		find /run/pi-share -mindepth 1 -maxdepth 1
	fi
}

stub_log() {
	if [[ -f /mnt/log/$1 ]]; then
		cat -- "/mnt/log/$1"
	fi
}
