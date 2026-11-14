#!/usr/bin/env bats
# The gitleaks filter: the binary pi-share trusts, the report it reads, and the [REDACTED] lines it
# leaves in the copies (see SPEC.md, "Filter every copy through gitleaks").

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
	SCAN=/run/pi-share/1000-0123456789abcdef/.scan
}

# plan REPORT [COUNT]: run plan_redactions over REPORT for COUNT staged files (default 2).
plan() {
	local report=$1 count=${2:-2}
	run bash -c 'source "$1" && plan_redactions "$2" "$3" "$4"' _ "$PI_SHARE" "$SCAN" "$count" "$report"
}

@test "require_gitleaks resolves a trusted binary" {
	run bash -c 'source "$1" && require_gitleaks /usr/bin/true' _ "$PI_SHARE"
	[ "$status" -eq 0 ]
	[ "$output" = "$(realpath -e /usr/bin/true)" ]
}

@test "require_gitleaks refuses a name that is not on PATH, naming it and the path list" {
	run bash -c 'source "$1" && PATH=/nonexistent require_gitleaks gitleaks' _ "$PI_SHARE"
	[ "$status" -eq 1 ]
	[[ $output == *"pi-share: gitleaks not found in /nonexistent"* ]]
	[[ $output == *"install gitleaks"* ]]
}

@test "require_gitleaks refuses a binary that is writable by group or other" {
	mkdir -p "$BATS_TEST_TMPDIR/writable"
	printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/writable/gitleaks"
	chmod 0777 "$BATS_TEST_TMPDIR/writable/gitleaks"
	run bash -c 'source "$1" && require_gitleaks "$2"' _ "$PI_SHARE" "$BATS_TEST_TMPDIR/writable/gitleaks"
	[ "$status" -eq 1 ]
	[[ $output == *"pi-share: refusing gitleaks at"* ]]
	[[ $output == *"(writable by group or others)"* ]]
}

@test "require_gitleaks refuses a binary that is not root's" {
	# stat is replaced, so the refusal does not depend on who runs the suite.
	run bash -c 'source "$1" && stat() { if [[ $* == *"%u"* ]]; then echo 1000; else command stat "$@"; fi; }; require_gitleaks "$2"' _ "$PI_SHARE" /usr/bin/true
	[ "$status" -eq 1 ]
	[[ $output == *"(not owned by root)"* ]]
}

@test "plan_redactions maps a report line to its staged file and line range" {
	plan "$(printf '%s/1\t7\t9\n' "$SCAN")"
	[ "$status" -eq 0 ]
	[ "$output" = "1 7 9" ]
}

@test "plan_redactions skips blank lines, drops duplicates and sorts by file then line" {
	plan "$(printf '%s/1\t5\t5\n\n%s/0\t9\t9\n%s/0\t3\t3\n%s/1\t5\t5\n' "$SCAN" "$SCAN" "$SCAN" "$SCAN")"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '0 3 3\n0 9 9\n1 5 5')" ]
}

@test "plan_redactions fails on a path outside the scan, a bad index and a bad range" {
	local file start end
	while read -r file start end; do
		plan "$(printf '%s\t%s\t%s\n' "$file" "$start" "$end")"
		[ "$status" -eq 1 ]
		[[ $output == *"unexpected gitleaks report line"* ]]
	done <<-CASES
		/run/pi-share/1000-fedcba9876543210/.scan/0 1 1
		$SCAN/2 1 1
		$SCAN/0 1x 1
		$SCAN/0 0 1
		$SCAN/0 5 4
	CASES
}

@test "plan_redactions fails on a line without exactly three tab-separated fields" {
	local line
	for line in "$SCAN/0\t1" "$SCAN/0\t1\t2\t3" "$SCAN/0\t\t2" "$SCAN/0\t1\t" "$SCAN/0"; do
		plan "$(printf '%b' "$line")"
		[ "$status" -eq 1 ]
		[[ $output == *"unexpected gitleaks report line"* ]]
	done
}

@test "a clean scan shares the copies unchanged and leaves no scan behind" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/app/conf "secret value" 0600
		share -- /mnt/data/app/conf
		[ "$rc" -eq 0 ]
		[ "$(printf "%s\n" "$out" | wc -l)" -eq 2 ]
		[[ $(printf "%s\n" "$out" | head -1) == expires* ]]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "secret value" ]
		[ "$(stat -c "%u:%g %a" "$copy")" = "1000:1000 400" ]
		dir=$(share_dirs)
		[ -z "$(find "$dir" -name ".filter")" ]
		[ "$(find "$dir" -type f | wc -l)" -eq 1 ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "the scan sees numbered names, not the requested paths or allowlisted names" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/package-lock.json "x"
		make_file /mnt/data/node_modules/secret.conf "y"
		share -- /mnt/data/package-lock.json /mnt/data/node_modules/secret.conf
		[ "$rc" -eq 0 ]
		[ "$(stub_log gitleaks-scan)" = "$(printf "0\n1")" ]
		[[ $(stub_log gitleaks) == *" -- "*"/.filter/scan" ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "gitleaks runs with the trusted report and no way for the caller to opt out" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "x"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		args=$(stub_log gitleaks)
		[[ $args == *"dir --no-banner --no-color --log-level error --exit-code 3 --ignore-gitleaks-allow"* ]]
		[[ $args == *" --gitleaks-ignore-path "*"/.filter/.gitleaksignore "* ]]
		[[ $args == *" --report-format template --report-template "*"/.filter/template "* ]]
		[[ $args == *" --report-path - -- "*"/.filter/scan" ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a finding replaces its line with [REDACTED] and leaves the rest" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "one
two
three"
		printf "@SCAN@/0\t2\t2\n" >/mnt/stub/gitleaks.out
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "one
[REDACTED]
three" ]
		[ "$(stat -c "%u:%g %a" "$copy")" = "1000:1000 400" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a range replaces every line in it, in every file, once per row" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/a "1
2
3
4"
		make_file /mnt/data/b "x
y"
		printf "@SCAN@/0\t2\t3\n@SCAN@/1\t2\t2\n@SCAN@/1\t2\t2\n" >/mnt/stub/gitleaks.out
		share -- /mnt/data/a /mnt/data/b
		[ "$rc" -eq 0 ]
		dir=$(share_dirs)
		[ "$(cat "$dir/mnt/data/a")" = "1
[REDACTED]
[REDACTED]
4" ]
		[ "$(cat "$dir/mnt/data/b")" = "x
[REDACTED]" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a redacting share says what it redacted and keeps stdout to the protocol" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/a "1
2"
		printf "@SCAN@/0\t2\t2\n" >/mnt/stub/gitleaks.out
		share -- /mnt/data/a
		[ "$rc" -eq 0 ]
		[[ $err == *"pi-share: gitleaks redacted 1 line(s) in 1 file(s)"* ]]
		[ "$(printf "%s\n" "$out" | wc -l)" -eq 2 ]
		[[ $(printf "%s\n" "$out" | head -1) == expires* ]]
		# Overlapping ranges count their shared line once: 2-3 and 3-4 are three lines.
		make_file /mnt/data/b "1
2
3
4"
		printf "@SCAN@/0\t2\t3\n@SCAN@/0\t3\t4\n" >/mnt/stub/gitleaks.out
		share -- /mnt/data/b
		[ "$rc" -eq 0 ]
		[[ $err == *"pi-share: gitleaks redacted 3 line(s) in 1 file(s)"* ]]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(sed -n 1p "$copy")" = 1 ]
		[ "$(sed -n 2p "$copy")" = "[REDACTED]" ]
		[ "$(sed -n 3p "$copy")" = "[REDACTED]" ]
		[ "$(sed -n 4p "$copy")" = "[REDACTED]" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "gitleaks exiting 1 fails the share, whatever it printed" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "1
2"
		stub_status gitleaks 1
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"filtering failed (gitleaks exit 1)"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[[ $(stub_log systemctl) == *"stop pi-share-1000-"* ]]
		printf "@SCAN@/0\t1\t1\n@SCAN@/0\t2\t2\n" >/mnt/stub/gitleaks.out
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "gitleaks exiting 2 fails the share and the message carries gitleaks' line" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "x"
		printf "FTL boom\033[31m\n" >/mnt/stub/gitleaks.err
		stub_status gitleaks 2
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"filtering failed (gitleaks exit 2); nothing shared: FTL boom"* ]]
		[[ $err != *$'"'"'\033'"'"'* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "an unexpected report row, or findings with no report, fails the share" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "x"
		printf "@SCAN@/7\t1\t1\n" >/mnt/stub/gitleaks.out
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"unexpected gitleaks report line"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		rm -f /mnt/stub/gitleaks.out
		stub_status gitleaks 3
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"filtering failed (gitleaks exit 3); nothing shared: it reported findings but listed none"* ]]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a missing gitleaks is refused before anything is created" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "x"
		rm -f /usr/local/bin/gitleaks
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"pi-share: gitleaks not found in "* ]]
		[[ $err == *"install gitleaks"* ]]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a gitleaks others can write is refused before anything is created" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "x"
		chmod 0777 /usr/local/bin/gitleaks
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"(writable by group or others)"* ]]
		[ -z "$out" ]
		[ ! -e /run/pi-share ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a gitleaks the caller put on its PATH is never run" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "1
2"
		printf "@SCAN@/0\t2\t2\n" >/mnt/stub/gitleaks.out
		mkdir -m 0777 /mnt/fake
		printf "#!/bin/sh\ntouch /mnt/log/fake-ran\nexit 0\n" >/mnt/fake/gitleaks
		chmod 0755 /mnt/fake/gitleaks
		PATH="/mnt/fake:$PATH" share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[ ! -e /mnt/log/fake-ran ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "1
[REDACTED]" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
