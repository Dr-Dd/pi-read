#!/usr/bin/env bats
# Verifying the redaction: every reported secret must be gone from its copy and gitleaks must find
# nothing in the redacted copies, or nothing is shared (see SPEC.md).

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
	SCAN=/run/pi-share/1000-0123456789abcdef/.filter/scan
}

b64() {
	printf '%s' "$1" | base64 -w0
}

# check DIR REPORT RESOLVED...: run check_secrets_gone over the copies under DIR.
check() {
	local dir=$1 report=$2
	shift 2
	run bash -c 'source "$1" && shift && check_secrets_gone "$@"' _ "$PI_SHARE" \
		"$dir" "$SCAN" "$report" "$BATS_TEST_TMPDIR/tmp" "$@"
}

# Report rows written by the sandbox snippets: "row FILE START END TAGS SECRET MATCH" appends a
# 6-field row to OUT (default /mnt/stub/gitleaks.out).
# shellcheck disable=SC2016 # expanded inside the sandbox
ROW='row() { printf "@SCAN@/%s\t%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" "$(printf "%b" "$5" | base64 -w0)" "$(printf "%b" "$6" | base64 -w0)" >>"${OUT:-/mnt/stub/gitleaks.out}"; }
'

@test "check_secrets_gone fails, naming the file but not the secret, when a decoded secret is still in its copy" {
	mkdir -p "$BATS_TEST_TMPDIR/d/etc"
	printf 'one\n[REDACTED]\nagain s3cretXYZ here\n' >"$BATS_TEST_TMPDIR/d/etc/a"
	printf 'clean\n' >"$BATS_TEST_TMPDIR/d/etc/b"
	# Reported for b, which no longer holds it: fine, whatever a holds.
	check "$BATS_TEST_TMPDIR/d" "$(printf '%s/1\t1\t1\t0\t%s\t%s\n' "$SCAN" "$(b64 s3cretXYZ)" "$(b64 s3cretXYZ)")" /etc/a /etc/b
	[ "$status" -eq 0 ]
	check "$BATS_TEST_TMPDIR/d" "$(printf '%s/0\t2\t2\t1\t%s\t%s\n' "$SCAN" "$(b64 s3cretXYZ)" "$(b64 s3cretXYZ)")" /etc/a /etc/b
	[ "$status" -eq 1 ]
	[ "$output" = "pi-share: filtering failed: a secret gitleaks reported is still in /etc/a; nothing shared" ]
	[[ $output != *s3cretXYZ* ]]
}

@test "check_secrets_gone passes when no reported secret is left, and ignores 3-field rows" {
	mkdir -p "$BATS_TEST_TMPDIR/d/etc"
	printf 'pw = [REDACTED]\nother line\n' >"$BATS_TEST_TMPDIR/d/etc/a"
	check "$BATS_TEST_TMPDIR/d" "$(printf '%s/0\t1\t1\t0\t%s\t%s\n%s/0\t2\t2\n\n' "$SCAN" "$(b64 p4ssw0rd)" "$(b64 'pw = p4ssw0rd')" "$SCAN")" /etc/a
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "check_secrets_gone skips a secret that is empty, holds a newline or a NUL, or is not valid base64" {
	mkdir -p "$BATS_TEST_TMPDIR/d/etc"
	# Every line of the copy holds a part of each secret, so a grep of any of them would match.
	printf 'AAAA\nBBBB\n' >"$BATS_TEST_TMPDIR/d/etc/a"
	local secret
	for secret in "" "$(b64 $'AAAA\nBBBB')" "$(printf 'AAAA\000' | base64 -w0)" "QUFBQQ=x"; do
		check "$BATS_TEST_TMPDIR/d" "$(printf '%s/0\t1\t2\t0\t%s\t%s\n' "$SCAN" "$secret" "$secret")" /etc/a
		[ "$status" -eq 0 ]
	done
}

@test "sudo: a clean first scan runs gitleaks once" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "nothing here"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[ "$(stub_log gitleaks | wc -l)" -eq 1 ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: after a redaction, gitleaks runs a second time with the same arguments over freshly staged, redacted copies" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/conf "user = admin
password = p4ssw0rd
end"
		row 0 2 2 0 p4ssw0rd "password = p4ssw0rd"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		[ "$(stub_log gitleaks | wc -l)" -eq 2 ]
		[ "$(stub_log gitleaks | sed -n 1p)" = "$(stub_log gitleaks | sed -n 2p)" ]
		[ "$(stub_log gitleaks-scan)" = "$(printf "0\n0")" ]
		second=$(stub_log gitleaks-content | sed -n "/^--- call 2$/,\$p")
		[[ $second == *"password = [REDACTED]"* ]]
		[[ $second != *p4ssw0rd* ]]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(sed -n 2p "$copy")" = "password = [REDACTED]" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a re-scan that still flags a copy shares nothing, and the unit is stopped" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "1
2
3"
		printf "@SCAN@/0\t2\t2\n" >/mnt/stub/gitleaks.out
		printf "@SCAN@/0\t3\t3\n" >/mnt/stub/gitleaks.rescan.out
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"pi-share: filtering failed: gitleaks still flags the redacted copies; nothing shared"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[[ $(stub_log systemctl) == *"stop pi-share-1000-"* ]]
		# Exit 3 alone counts as a finding too.
		rm -f /mnt/stub/gitleaks.rescan.out
		stub_status gitleaks.rescan 3
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"gitleaks still flags the redacted copies"* ]]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a re-scan where gitleaks exits 1 shares nothing and says it was the re-scan" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "1
2"
		printf "@SCAN@/0\t2\t2\n" >/mnt/stub/gitleaks.out
		printf "FTL rescan broke\n" >/mnt/stub/gitleaks.rescan.err
		stub_status gitleaks.rescan 1
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"filtering failed (gitleaks exit 1 on the re-scan); nothing shared: FTL rescan broke"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a reported line that is off (whole-line row on the wrong line, secret on another line) shares nothing, and the error does not contain the secret" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/conf "first
pw = s3cretXYZ
last"
		# Tagged: a whole-line row, reported one line too early.
		row 0 1 1 1 s3cretXYZ s3cretXYZ
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"a secret gitleaks reported is still in /mnt/data/conf; nothing shared"* ]]
		[[ $err != *s3cretXYZ* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		# Untagged: the secret is not on the reported line, which goes whole, and the secret stays.
		rm -f /mnt/stub/gitleaks.out
		row 0 3 3 0 s3cretXYZ "pw = s3cretXYZ"
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"a secret gitleaks reported is still in /mnt/data/conf; nothing shared"* ]]
		[[ $err != *s3cretXYZ* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a partial secret that also appears unflagged on another line shares nothing" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/conf "pw = s3cretXYZ
middle
again: s3cretXYZ"
		row 0 1 1 0 s3cretXYZ "pw = s3cretXYZ"
		share -- /mnt/data/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"a secret gitleaks reported is still in /mnt/data/conf; nothing shared"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a multi-line secret whose lines also appear elsewhere is not grepped, and the share succeeds" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/conf "AAAA
BBBB
other
AAAA"
		row 0 1 2 0 "AAAA\nBBBB" "AAAA\nBBBB"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "[REDACTED]
[REDACTED]
other
AAAA" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a listing whose re-scan still flags it lists nothing" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/a "x"
		make_file /mnt/data/b "x"
		printf "@SCAN@/0\t3\t3\n" >/mnt/stub/gitleaks.out
		printf "@SCAN@/0\t4\t4\n" >/mnt/stub/gitleaks.rescan.out
		share --list -- /mnt/data
		[ "$rc" -eq 1 ]
		[[ $err == *"gitleaks still flags the redacted copies; nothing shared"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "the installed gitleaks (skipped when absent) does not flag a stripe-key line after redact_line, nor a whole [REDACTED] line" {
	local gitleaks line
	gitleaks=$(command -v gitleaks) || skip "gitleaks is not installed"
	mkdir -p "$BATS_TEST_TMPDIR/scan"
	line=$(bash -c 'source "$1" && redact_line "$2" "$3" "$3"' _ "$PI_SHARE" \
		"Token  sk_live_51HxQ2aBcDeFgHiJkLmNoPqRsT" sk_live_51HxQ2aBcDeFgHiJkLmNoPqRsT)
	[ "$line" = "Token  [REDACTED]" ]
	printf 'first\n%s\n[REDACTED]\n' "$line" >"$BATS_TEST_TMPDIR/scan/0"
	bash -c 'source "$1" && printf "%s" "$REPORT_TEMPLATE"' _ "$PI_SHARE" >"$BATS_TEST_TMPDIR/template"
	# Through pi-share's own run_gitleaks, so the scan runs exactly as the re-scan does (env -i, the
	# ignore flags), whatever GITLEAKS_CONFIG* the tester's environment holds.
	run bash -c 'source "$1" && run_gitleaks "$2" "$3" "$4"' _ "$PI_SHARE" \
		"$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/scan" "$gitleaks"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
