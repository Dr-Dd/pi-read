#!/usr/bin/env bats

setup() {
	INSTALL="$BATS_TEST_DIRNAME/../../install.sh"
	REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
	STUBS="$BATS_TEST_TMPDIR/stubs"
	LOG="$BATS_TEST_TMPDIR/log"
	mkdir -p "$STUBS"
	: >"$LOG"
	export LOG
	# Each stub logs "name args..." and fails when FAIL_<name> matches its arguments.
	local cmd
	for cmd in pi sudo visudo systemctl systemd-run gitleaks; do
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

@test "sourcing install.sh defines main without running it" {
	# Stubs on PATH: if main ran anyway, they would log it instead of running the real commands.
	run env PATH="$STUBS:$PATH" bash -c 'source "$1" && declare -F main' _ "$INSTALL"
	[ "$status" -eq 0 ]
	[ "$output" = "main" ]
	[ ! -s "$LOG" ]
}

@test "--help exits 0 with usage; an unknown option exits 2" {
	run "$INSTALL" --help
	[ "$status" -eq 0 ]
	[[ $output == *usage:* ]]
	run "$INSTALL" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *usage:* ]]
}

@test "install: sudo installs pi-share, the list check and the sudoers file, then visudo -c" {
	run_install
	[ "$status" -eq 0 ]
	run grep -nE '^(pi|sudo) ' "$LOG"
	[[ ${lines[0]} == *"sudo install -m 0755 -o root -g root -- $REPO/bin/pi-share /usr/local/bin/pi-share" ]]
	[[ ${lines[1]} == *"sudo test -e /usr/local/etc/pi-read/never-share.list -o -L /usr/local/etc/pi-read/never-share.list" ]]
	[[ ${lines[2]} == *"sudo cmp -s -- $REPO/never-share.defaults /usr/local/etc/pi-read/never-share.list" ]]
	[[ ${lines[3]} == *"sudo install -m 0440 -o root -g root -- "*" /etc/sudoers.d/pi-read" ]]
	[[ ${lines[4]} == *"sudo visudo -cq" ]]
	[ "${#lines[@]}" -eq 5 ]
}

@test "install: a rule rejected by visudo -cf never installs the sudoers file" {
	FAIL_visudo='-cqf*' run_install
	[ "$status" -ne 0 ]
	! grep -q 'sudoers.d' "$LOG"
}

@test "install: a failing sudo visudo -c removes the sudoers file" {
	FAIL_sudo='visudo -c*' run_install
	[ "$status" -ne 0 ]
	run tail -n 1 "$LOG"
	[ "$output" = "sudo rm -f -- /etc/sudoers.d/pi-read" ]
}

@test "a missing required command fails before anything runs, naming it" {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	rm "$STUBS/sudo"
	local cmd
	for cmd in dirname uname; do
		ln -s "$(command -v "$cmd")" "$STUBS/$cmd"
	done
	run env PATH="$STUBS" "$BASH" "$INSTALL"
	[ "$status" -eq 1 ]
	[[ $output == *"required command not found: sudo"* ]]
	[ ! -s "$LOG" ]
}

@test "--uninstall: sudo removes both files" {
	run_install --uninstall
	[ "$status" -eq 0 ]
	run cat "$LOG"
	[ "${lines[0]}" = "sudo rm -f -- /usr/local/bin/pi-share /etc/sudoers.d/pi-read" ]
	[ "${#lines[@]}" -eq 1 ]
}
