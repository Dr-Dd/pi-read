#!/usr/bin/env bats
# install.sh does only the system step: pi installs the extension from git, so install.sh never
# runs pi (from pi's copy, `pi install <dir>` would add a second, local-path entry).

setup() {
	INSTALL="$BATS_TEST_DIRNAME/../../install.sh"
	STUBS="$BATS_TEST_TMPDIR/stubs"
	LOG="$BATS_TEST_TMPDIR/log"
	SOURCE=git:github.com/Dr-Dd/pi-read
	mkdir -p "$STUBS"
	: >"$LOG"
	export LOG
	local cmd
	for cmd in pi sudo visudo systemctl systemd-run gitleaks; do
		make_stub "$cmd"
	done
}

# Each stub logs "name args..."; the pi stub always fails.
make_stub() {
	cat >"$STUBS/$1" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
echo "$name $*" >>"$LOG"
[[ $name != pi ]]
EOF
	chmod +x "$STUBS/$1"
}

run_install() {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	run env PATH="$STUBS:$PATH" "$INSTALL" "$@"
}

@test "install never calls pi and succeeds when pi fails" {
	run_install
	[ "$status" -eq 0 ]
	[ "$(grep -c '^pi ' "$LOG")" -eq 0 ]
}

@test "install names the pi install source and no longer says to keep this folder" {
	run_install
	[ "$status" -eq 0 ]
	[[ $output == *"pi install $SOURCE"* ]]
	[[ $output != *"keep this folder"* ]]
}

@test "--uninstall never calls pi and names pi remove" {
	run_install --uninstall
	[ "$status" -eq 0 ]
	[ "$(grep -c '^pi ' "$LOG")" -eq 0 ]
	[[ $output == *"pi remove $SOURCE"* ]]
}

@test "--uninstall --purge never calls pi and names pi remove" {
	run_install --uninstall --purge
	[ "$status" -eq 0 ]
	[ "$(grep -c '^pi ' "$LOG")" -eq 0 ]
	[[ $output == *"pi remove $SOURCE"* ]]
}

@test "--uninstall succeeds without pi on PATH" {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	rm "$STUBS/pi"
	local cmd
	for cmd in bash basename dirname uname; do
		ln -s "$(command -v "$cmd")" "$STUBS/$cmd"
	done
	run env PATH="$STUBS" "$BASH" "$INSTALL" --uninstall
	[ "$status" -eq 0 ]
	grep -q '^sudo rm -f -- /usr/local/bin/pi-share /etc/sudoers.d/pi-read$' "$LOG"
}
