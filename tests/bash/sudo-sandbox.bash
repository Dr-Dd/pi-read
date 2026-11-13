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
#   - bind-mounts placeholder stubs over /usr/bin/systemd-run and /usr/bin/systemctl;
#   - installs pi-share root-owned 0755 at /mnt/bin/pi-share.
# Then it evaluates SNIPPET as sandbox root with errexit on, so a failing `[ ... ]` fails the test
# (the failing command is printed). Everything disappears with the namespace.
#
# Functions available to SNIPPET:
#   as_tester CMD...       run CMD as user tester (uid/gid 1000) through `sudo -n`
#   share ARGS...          run `sudo -n /mnt/bin/pi-share ARGS...` as tester; sets rc, out, err
#   make_file PATH TEXT [MODE] [OWNER]   create a file (parents root-owned 0755)
#   stub_status NAME RC    make a stub exit RC: NAME is systemd-run or systemctl-is-active
#   share_dirs             print the share dirs under /run/pi-share (one per line)
#   stub_log NAME          print the arguments the stub was called with (one call per line)

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
	local pi_share=$1 s=/mnt f
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

	printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' \
		"tester:x:${TESTER_UID}:${TESTER_UID}:tester:/mnt:/bin/bash" >"${s}/etc/passwd"
	printf '%s\n' 'root:x:0:' "tester:x:${TESTER_UID}:" >"${s}/etc/group"
	# PLACEHOLDER for the sudoers rule install.sh will add (install.sh does not exist yet).
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
		exit 0
	EOF
	chmod 0755 "${s}/stub/systemd-run" "${s}/stub/systemctl"
	mount --bind "${s}/stub/systemd-run" /usr/bin/systemd-run
	mount --bind "${s}/stub/systemctl" /usr/bin/systemctl
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
