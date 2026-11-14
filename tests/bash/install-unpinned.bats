#!/usr/bin/env bats
# pi-read is installed unpinned, so install.sh's summary names the source without a tag.

setup() {
	INSTALL="$BATS_TEST_DIRNAME/../../install.sh"
	STUBS="$BATS_TEST_TMPDIR/stubs"
	LOG="$BATS_TEST_TMPDIR/log"
	mkdir -p "$STUBS"
	: >"$LOG"
	export LOG
	local cmd
	for cmd in sudo visudo systemctl systemd-run gitleaks; do
		printf '#!/usr/bin/env bash\necho "$(basename "$0") $*" >>"$LOG"\n' >"$STUBS/$cmd"
		chmod +x "$STUBS/$cmd"
	done
}

@test "install names the unpinned pi install source and says to rerun after a pi update" {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	run env PATH="$STUBS:$PATH" "$INSTALL"
	[ "$status" -eq 0 ]
	[[ $output == *"pi install git:github.com/Dr-Dd/pi-read"$'\n'* ]]
	[[ $output != *"@<tag>"* ]]
	[[ $output == *"again after every pi update of pi-read"* ]]
}
