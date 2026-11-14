#!/usr/bin/env bats
# install.sh installs the never-share list only when none is installed, never overwrites it, and
# keeps it on uninstall unless --purge.

setup() {
	INSTALL="$BATS_TEST_DIRNAME/../../install.sh"
	REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
	STUBS="$BATS_TEST_TMPDIR/stubs"
	LOG="$BATS_TEST_TMPDIR/log"
	LIST=/usr/local/etc/pi-read/never-share.list
	mkdir -p "$STUBS"
	: >"$LOG"
	export LOG
	# Each stub logs "name args..." and fails when FAIL_<name> matches its arguments.
	local cmd
	for cmd in pi sudo visudo systemctl systemd-run; do
		make_stub "$cmd"
	done
}

make_stub() {
	cat >"$STUBS/$1" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
echo "$name $*" >>"$LOG"
var="FAIL_${name//-/_}"
pattern=${!var-}
if [[ -n $pattern && "$*" == $pattern ]]; then exit 1; fi
exit 0
EOF
	chmod +x "$STUBS/$1"
}

run_install() {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	run env PATH="$STUBS:$PATH" "$INSTALL" "$@"
}

@test "install: with no list installed, the defaults are installed root-owned 0644 before the sudoers file" {
	FAIL_sudo='test -e*' run_install
	[ "$status" -eq 0 ]
	run grep -E '^sudo ' "$LOG"
	[ "${lines[1]}" = "sudo test -e $LIST -o -L $LIST" ]
	[ "${lines[2]}" = "sudo install -d -m 0755 -o root -g root -- /usr/local/etc/pi-read" ]
	[ "${lines[3]}" = "sudo install -m 0644 -o root -g root -- $REPO/never-share.defaults $LIST" ]
	[[ ${lines[4]} == "sudo install -m 0440 -o root -g root -- "*" /etc/sudoers.d/pi-read" ]]
	[ "$(grep -c '^sudo cmp ' "$LOG")" -eq 0 ]
}

@test "install: an existing list is never overwritten" {
	run_install
	[ "$status" -eq 0 ]
	[[ $output != *"differs from the shipped defaults"* ]]
	[ "$(grep -c "^sudo install .*never-share.defaults $LIST\$" "$LOG")" -eq 0 ]
	[ "$(grep -c '^sudo install -d ' "$LOG")" -eq 0 ]
}

@test "install: a kept list that differs from the defaults is reported with the diff command" {
	FAIL_sudo='cmp -s*' run_install
	[ "$status" -eq 0 ]
	[[ $output == *"Kept your never-share list $LIST; it differs from the shipped defaults."* ]]
	[[ $output == *"sudo diff -u $REPO/never-share.defaults $LIST"* ]]
	[[ $output == *"--reset-never-share"* ]]
	[ "$(grep -c '^sudo install -d ' "$LOG")" -eq 0 ]
}

@test "install: a failing list install stops before the sudoers file" {
	FAIL_sudo='@(test -e*|install -m 0644*)' run_install
	[ "$status" -ne 0 ]
	[[ $output == *"could not install $LIST"* ]]
	[ "$(grep -c 'sudoers.d' "$LOG")" -eq 0 ]
}

@test "--reset-never-share installs the defaults over the existing list" {
	run_install --reset-never-share
	[ "$status" -eq 0 ]
	run cat "$LOG"
	[ "${lines[0]}" = "sudo install -d -m 0755 -o root -g root -- /usr/local/etc/pi-read" ]
	[ "${lines[1]}" = "sudo install -m 0644 -o root -g root -- $REPO/never-share.defaults $LIST" ]
	[ "${#lines[@]}" -eq 2 ]
}

@test "--uninstall keeps the list and names --purge" {
	run_install --uninstall
	[ "$status" -eq 0 ]
	[ "$(grep -c 'never-share' "$LOG")" -eq 0 ]
	[[ $output == *"Kept your never-share list $LIST"* ]]
	[[ $output == *"--uninstall --purge"* ]]
}

@test "--uninstall --purge removes the list and its directory before pi remove" {
	run_install --uninstall --purge
	[ "$status" -eq 0 ]
	run cat "$LOG"
	[ "${lines[0]}" = "sudo rm -f -- /usr/local/bin/pi-share /etc/sudoers.d/pi-read" ]
	[ "${lines[1]}" = "sudo rm -f -- $LIST" ]
	[ "${lines[2]}" = "sudo rmdir -- /usr/local/etc/pi-read" ]
	[ "${lines[3]}" = "pi remove $REPO" ]
	[ "${#lines[@]}" -eq 4 ]
}

@test "an unknown second option exits 2 with usage" {
	local args
	for args in "--uninstall --bogus" "--purge --uninstall" "--reset-never-share --purge"; do
		# shellcheck disable=SC2086 # split on purpose
		run "$INSTALL" $args
		[ "$status" -eq 2 ]
		[[ $output == *usage:* ]]
	done
}
