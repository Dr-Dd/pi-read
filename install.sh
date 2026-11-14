#!/usr/bin/env bash
# install.sh: install (or remove) pi-read. See README.md.
#
#   ./install.sh                      install the pi extension, pi-share, its sudoers rule and,
#                                     when none is installed yet, the default never-share list
#   ./install.sh --reset-never-share  replace the never-share list with the shipped defaults
#   ./install.sh --uninstall          remove all of them but the never-share list
#   ./install.sh --uninstall --purge  remove the never-share list too
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

die() {
	echo "install.sh: $*" >&2
	exit 1
}

usage() {
	echo "usage: ./install.sh [--reset-never-share | --uninstall [--purge]]" >&2
	exit "${1:-2}"
}

# repo_dir: print the absolute directory of this script (the pi package root).
repo_dir() {
	(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
}

# sudoers_rule: print the sudoers rule. It grants nothing; it only makes sudo ask for the
# password every time pi-share runs, so no cached sudo session is left for other programs.
sudoers_rule() {
	echo "# Installed by pi-read's install.sh: always ask for the password for pi-share."
	echo "Defaults!${PI_SHARE_DEST} timestamp_timeout=0"
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

do_install() {
	local dir tmp
	dir=$(repo_dir)
	preflight pi sudo visudo systemctl systemd-run

	# First, so a failure leaves the system files untouched.
	pi install "${dir}" || die "pi install failed"

	tmp=$(mktemp)
	# shellcheck disable=SC2064 # expand tmp now
	trap "rm -f -- '${tmp}'" EXIT
	sudoers_rule >"${tmp}"
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

	echo "Installed pi-read:"
	echo "  pi extension  ${dir} (keep this folder where it is)"
	echo "  pi-share      ${PI_SHARE_DEST}"
	echo "  never-share   ${NEVER_SHARE_DEST} (edit with: sudoedit ${NEVER_SHARE_DEST})"
	echo "  sudoers rule  ${SUDOERS_DEST}"
	echo "Remove everything with: ${dir}/install.sh --uninstall"
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
	preflight pi sudo
	# Running shares expire on their own: their cleanup service does not use pi-share.
	echo "Removing ${PI_SHARE_DEST} and ${SUDOERS_DEST} (needs sudo)"
	sudo rm -f -- "${PI_SHARE_DEST}" "${SUDOERS_DEST}" || die "could not remove the system files"
	if [[ ${purge} == purge ]]; then
		echo "Removing ${NEVER_SHARE_DEST}"
		sudo rm -f -- "${NEVER_SHARE_DEST}" || die "could not remove ${NEVER_SHARE_DEST}"
		sudo rmdir -- "${NEVER_SHARE_DIR}" 2>/dev/null || true
	fi
	pi remove "${dir}" || die "pi remove failed"
	echo "Uninstalled pi-read."
	if [[ ${purge} != purge ]]; then
		echo "Kept your never-share list ${NEVER_SHARE_DEST}; remove it with: ${dir}/install.sh --uninstall --purge"
	fi
}

main() {
	case $# in
	0) do_install ;;
	1)
		case $1 in
		--uninstall) do_uninstall ;;
		--reset-never-share) do_reset_never_share ;;
		-h | --help) usage 0 ;;
		*) usage ;;
		esac
		;;
	2)
		[[ $1 == --uninstall && $2 == --purge ]] || usage
		do_uninstall purge
		;;
	*) usage ;;
	esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
