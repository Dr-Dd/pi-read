#!/usr/bin/env bash
# install.sh: install (or remove) pi-read's system files. See README.md.
#
# The pi extension is installed separately, by pi itself, from git:
#   pi install git:github.com/Dr-Dd/pi-read
# This script does only the system step, from pi's copy of the package (or a local clone):
#
#   ./install.sh                      install pi-share, its sudoers rule and, when none is
#                                     installed yet, the default never-share list
#   ./install.sh --password-timeout D the same, with sudo remembering the password for pi-share
#                                     for D (90, 90s, 2m, 1h; 0, the default, asks every time)
#   ./install.sh --reset-never-share  replace the never-share list with the shipped defaults
#   ./install.sh --uninstall          remove all of them but the never-share list
#   ./install.sh --uninstall --purge  remove the never-share list too
#
# It never runs pi: run from pi's copy, `pi install <this folder>` would add a second, local-path
# package entry next to the git one. Run it again after every update of the extension.
#
# Run it as your normal user; it asks for your sudo password for the system files.
# Tests source this file to call its functions; main only runs when it is executed.

# shellcheck disable=SC2310,SC2312 # every call site handles failure explicitly (|| die)
set -euo pipefail

# The extension in src/ calls pi-share at this same path (PI_SHARE_PATH in src/config.ts);
# tests/share-path.test.ts fails when the two differ.
readonly PI_SHARE_DEST=/usr/local/bin/pi-share
readonly SUDOERS_DEST=/etc/sudoers.d/pi-read
# pi-share reads the never-share list here (NEVER_SHARE_LIST in bin/pi-share, NEVER_SHARE_LIST_PATH
# in src/config.ts); tests/never-share-path.test.ts fails when they differ. Root edits it in place.
readonly NEVER_SHARE_DIR=/usr/local/etc/pi-read
readonly NEVER_SHARE_DEST=${NEVER_SHARE_DIR}/never-share.list
# The pi package source, without a ref (pi matches packages by repository, not by ref).
# tests/install-source.test.ts checks README.md installs this source as it is.
readonly PI_SOURCE=git:github.com/Dr-Dd/pi-read
# How long sudo remembers the password for pi-share, in seconds, unless --password-timeout says
# otherwise. Not remembered between runs: install.sh writes this default again without the option.
# 0: sudo asks every time. A remembered password can be reused, with no question, by a process pi
# starts in pi's own session (pi.exec()), and every probe restarts the time, so it is opt-in.
readonly DEFAULT_PASSWORD_TIMEOUT=0
readonly MAX_PASSWORD_TIMEOUT=3600
# pi-share's own sudo cache, apart from the one every other sudo command uses.
readonly PI_SHARE_TIMESTAMPDIR=/run/sudo/pi-read

die() {
	echo "install.sh: $*" >&2
	exit 1
}

usage() {
	echo "usage: ./install.sh [--password-timeout DURATION | --reset-never-share | --uninstall [--purge]]" >&2
	exit "${1:-2}"
}

# repo_dir: print the absolute directory of this script (the pi package root).
repo_dir() {
	(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
}

# parse_timeout SPEC: print SPEC (0, 90, 90s, 2m, 1h) in seconds, from 0 to MAX_PASSWORD_TIMEOUT.
parse_timeout() {
	local spec=$1 number seconds
	if [[ ! ${spec} =~ ^([0-9]{1,6})([smh]?)$ ]]; then
		echo "install.sh: invalid password timeout: ${spec} (0, 90, 90s, 2m, 1h)" >&2
		return 1
	fi
	number=$((10#${BASH_REMATCH[1]}))
	case ${BASH_REMATCH[2]} in
	m) seconds=$((number * 60)) ;;
	h) seconds=$((number * 3600)) ;;
	*) seconds=${number} ;;
	esac
	if ((seconds > MAX_PASSWORD_TIMEOUT)); then
		echo "install.sh: the password timeout must be between 0 and 1h: ${spec}" >&2
		return 1
	fi
	echo "${seconds}"
}

# minutes SECONDS: print SECONDS in minutes, as sudo's timestamp_timeout takes them: up to six
# decimals, trailing zeros dropped (30 -> 0.5, 90 -> 1.5, 20 -> 0.333333, 0 -> 0).
minutes() {
	local seconds=$1 whole frac
	whole=$((seconds / 60))
	frac=$(((seconds % 60) * 1000000 / 60))
	if ((frac == 0)); then
		echo "${whole}"
		return 0
	fi
	frac=$(printf '%06d' "${frac}")
	while [[ ${frac} == *0 ]]; do
		frac=${frac%0}
	done
	echo "${whole}.${frac}"
}

# sudoers_rule [SECONDS]: print the sudoers rule. It grants nothing; it sets how long sudo
# remembers the password for pi-share (0: ask every time). The cache is pi-share's own
# (timestampdir), so it never lets other commands run without a password and the user's
# normal sudo cache never approves pi-share; and it belongs to the process that ran sudo
# (timestamp_type=ppid), so another pi does not reuse it, nor a command pi runs in a new session
# (its bash tool); a process pi runs in its own session (pi.exec()) can.
sudoers_rule() {
	local seconds=${1:-${DEFAULT_PASSWORD_TIMEOUT}}
	if ((seconds == 0)); then
		echo "# Installed by pi-read's install.sh: sudo asks for the password for pi-share every time."
	else
		echo "# Installed by pi-read's install.sh: sudo remembers the password for pi-share for ${seconds} seconds, for one pi process."
	fi
	echo "Defaults!${PI_SHARE_DEST} timestamp_timeout=$(minutes "${seconds}"), timestamp_type=ppid, timestampdir=${PI_SHARE_TIMESTAMPDIR}"
}

# require CMD...: fail naming the first command not on PATH.
require() {
	local cmd
	for cmd in "$@"; do
		command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
	done
}

preflight() {
	((EUID != 0)) || die "run as your normal user, not root; it asks for sudo when needed"
	[[ $(uname -s) == Linux ]] || die "pi-read needs Linux with systemd"
	require "$@"
}

# install_defaults DIR: install DIR/never-share.defaults as the never-share list, root-owned 0644,
# replacing any list already there.
install_defaults() {
	sudo install -d -m 0755 -o root -g root -- "${NEVER_SHARE_DIR}" &&
		sudo install -m 0644 -o root -g root -- "$1/never-share.defaults" "${NEVER_SHARE_DEST}"
}

# ensure_never_share DIR: install the default never-share list when none is installed. An existing
# list is never overwritten (root edits it in place); say so when it differs from the defaults.
ensure_never_share() {
	local dir=$1
	if ! sudo test -e "${NEVER_SHARE_DEST}" -o -L "${NEVER_SHARE_DEST}"; then
		install_defaults "${dir}" || die "could not install ${NEVER_SHARE_DEST}"
		return 0
	fi
	if ! sudo cmp -s -- "${dir}/never-share.defaults" "${NEVER_SHARE_DEST}"; then
		echo "Kept your never-share list ${NEVER_SHARE_DEST}; it differs from the shipped defaults."
		echo "  compare: sudo diff -u ${dir}/never-share.defaults ${NEVER_SHARE_DEST}"
		echo "  restore the defaults: ${dir}/install.sh --reset-never-share"
	fi
}

# do_install [SECONDS]: install, with sudo remembering the password for SECONDS.
do_install() {
	local dir tmp seconds=${1:-${DEFAULT_PASSWORD_TIMEOUT}}
	dir=$(repo_dir)
	preflight sudo visudo systemctl systemd-run gitleaks

	tmp=$(mktemp)
	# shellcheck disable=SC2064 # expand tmp now
	trap "rm -f -- '${tmp}'" EXIT
	sudoers_rule "${seconds}" >"${tmp}"
	visudo -cqf "${tmp}" >/dev/null || die "the sudoers rule did not validate; nothing installed in /etc"

	echo "Installing ${PI_SHARE_DEST} and ${SUDOERS_DEST} (needs sudo)"
	sudo install -m 0755 -o root -g root -- "${dir}/bin/pi-share" "${PI_SHARE_DEST}" ||
		die "could not install ${PI_SHARE_DEST}"
	ensure_never_share "${dir}"
	sudo install -m 0440 -o root -g root -- "${tmp}" "${SUDOERS_DEST}" ||
		die "could not install ${SUDOERS_DEST}"
	if ! sudo visudo -cq >/dev/null; then
		sudo rm -f -- "${SUDOERS_DEST}"
		die "sudo's configuration did not validate with ${SUDOERS_DEST}; removed it"
	fi

	echo "Installed pi-read's system files:"
	echo "  pi-share      ${PI_SHARE_DEST}"
	echo "  never-share   ${NEVER_SHARE_DEST} (edit with: sudoedit ${NEVER_SHARE_DEST})"
	echo "  sudoers rule  ${SUDOERS_DEST}"
	if ((seconds == 0)); then
		echo "sudo asks for your password for pi-share every time."
	else
		echo "sudo remembers your password for pi-share for ${seconds} seconds."
	fi
	echo "Change it with: ${dir}/install.sh --password-timeout DURATION (0 asks every time; pass it again on every run)."
	echo "The pi extension is installed separately: pi install ${PI_SOURCE}"
	echo "Run ${dir}/install.sh again after every pi update of pi-read."
	echo "Remove the system files with: ${dir}/install.sh --uninstall"
}

do_reset_never_share() {
	local dir
	dir=$(repo_dir)
	preflight sudo
	echo "Replacing ${NEVER_SHARE_DEST} with the shipped defaults (needs sudo)"
	install_defaults "${dir}" || die "could not install ${NEVER_SHARE_DEST}"
	echo "Restored the default never-share list."
}

# do_uninstall [purge]: remove pi-read; the never-share list too with "purge".
do_uninstall() {
	local dir purge=${1-}
	dir=$(repo_dir)
	preflight sudo
	# Running shares expire on their own: their cleanup service does not use pi-share.
	echo "Removing ${PI_SHARE_DEST} and ${SUDOERS_DEST} (needs sudo)"
	sudo rm -f -- "${PI_SHARE_DEST}" "${SUDOERS_DEST}" || die "could not remove the system files"
	if [[ ${purge} == purge ]]; then
		echo "Removing ${NEVER_SHARE_DEST}"
		sudo rm -f -- "${NEVER_SHARE_DEST}" || die "could not remove ${NEVER_SHARE_DEST}"
		sudo rmdir -- "${NEVER_SHARE_DIR}" 2>/dev/null || true
	fi
	echo "Removed pi-read's system files."
	if [[ ${purge} != purge ]]; then
		echo "Kept your never-share list ${NEVER_SHARE_DEST}; remove it with: ${dir}/install.sh --uninstall --purge"
	fi
	echo "Remove the pi extension with: pi remove ${PI_SOURCE}"
}

main() {
	case $# in
	0) do_install ;;
	1)
		case $1 in
		--uninstall) do_uninstall ;;
		--reset-never-share) do_reset_never_share ;;
		--password-timeout) usage ;;
		-h | --help) usage 0 ;;
		*) usage ;;
		esac
		;;
	2)
		case $1 in
		--uninstall)
			[[ $2 == --purge ]] || usage
			do_uninstall purge
			;;
		--password-timeout)
			local seconds
			seconds=$(parse_timeout "$2") || usage
			do_install "${seconds}"
			;;
		*) usage ;;
		esac
		;;
	*) usage ;;
	esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
