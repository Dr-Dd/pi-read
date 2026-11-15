#!/usr/bin/env bats
# install.sh's sudoers rule and its --password-timeout option.

setup() {
	INSTALL="$BATS_TEST_DIRNAME/../../install.sh"
	STUBS="$BATS_TEST_TMPDIR/stubs"
	LOG="$BATS_TEST_TMPDIR/log"
	mkdir -p "$STUBS"
	: >"$LOG"
	export LOG
	local cmd
	for cmd in pi sudo visudo systemctl systemd-run gitleaks; do
		printf '#!/usr/bin/env bash\necho "$(basename "$0") $*" >>"$LOG"\n' >"$STUBS/$cmd"
		chmod +x "$STUBS/$cmd"
	done
	# visudo -cqf FILE also keeps a copy of the rule it checked.
	printf '#!/usr/bin/env bash\necho "visudo $*" >>"$LOG"\n[[ $1 == -cqf ]] && cp -- "$2" "%s"\nexit 0\n' \
		"$BATS_TEST_TMPDIR/rule" >"$STUBS/visudo"
}

run_install() {
	[ "$(id -u)" -ne 0 ] || skip "running as root"
	run env PATH="$STUBS:$PATH" "$INSTALL" "$@"
}

rule_of() {
	bash -c 'source "$1" && sudoers_rule "${@:2}"' _ "$INSTALL" "$@" | grep -v '^#'
}

@test "sudoers_rule defaults to 30 seconds per process in its own directory and passes visudo" {
	[ "$(rule_of)" = "Defaults!/usr/local/bin/pi-share timestamp_timeout=0.5, timestamp_type=ppid, timestampdir=/run/sudo/pi-read" ]
	command -v visudo >/dev/null || skip "visudo not installed"
	bash -c 'source "$1" && sudoers_rule' _ "$INSTALL" >"$BATS_TEST_TMPDIR/checked"
	run visudo -cf "$BATS_TEST_TMPDIR/checked"
	[ "$status" -eq 0 ]
}

@test "sudoers_rule writes 90 as 1.5, 20 as 0.333333 and 0 as 0 minutes" {
	[[ $(rule_of 90) == *" timestamp_timeout=1.5, "* ]]
	[[ $(rule_of 20) == *" timestamp_timeout=0.333333, "* ]]
	[[ $(rule_of 0) == *" timestamp_timeout=0, "* ]]
	[[ $(rule_of 3600) == *" timestamp_timeout=60, "* ]]
}

@test "install --password-timeout 2m installs and reports 120 seconds; a plain install reports 30" {
	run_install --password-timeout 2m
	[ "$status" -eq 0 ]
	[[ $output == *"sudo remembers your password for pi-share for 120 seconds."* ]]
	grep -q ' timestamp_timeout=2, ' "$BATS_TEST_TMPDIR/rule"
	grep -q '^sudo install -m 0440 -o root -g root -- .* /etc/sudoers.d/pi-read$' "$LOG"

	: >"$LOG"
	run_install
	[ "$status" -eq 0 ]
	[[ $output == *"sudo remembers your password for pi-share for 30 seconds."* ]]
	grep -q ' timestamp_timeout=0.5, ' "$BATS_TEST_TMPDIR/rule"

	run_install --password-timeout 0
	[ "$status" -eq 0 ]
	[[ $output == *"sudo asks for your password for pi-share every time."* ]]
	grep -q ' timestamp_timeout=0, ' "$BATS_TEST_TMPDIR/rule"
}

@test "--password-timeout rejects abc, -1, 2h, 1.5m and a missing value, running nothing" {
	local bad
	for bad in abc -1 2h 1.5m; do
		run_install --password-timeout "$bad"
		[ "$status" -eq 2 ]
		[[ $output == *usage:* ]]
	done
	run_install --password-timeout
	[ "$status" -eq 2 ]
	[ ! -s "$LOG" ]
}

@test "--password-timeout with --uninstall exits 2" {
	run_install --uninstall --password-timeout 30
	[ "$status" -eq 2 ]
	run_install --password-timeout 30 --uninstall
	[ "$status" -eq 2 ]
	[ ! -s "$LOG" ]
}
