#!/usr/bin/env bats
# Partial redaction: only the secret gitleaks reports is replaced on its line, and the whole line
# whenever the secret cannot be located safely (see SPEC.md).

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
	SCAN=/run/pi-share/1000-0123456789abcdef/.scan
}

# redact LINE SECRET MATCH...: run redact_line.
redact() {
	run bash -c 'source "$1" && shift && redact_line "$@"' _ "$PI_SHARE" "$@"
}

# plan REPORT [COUNT]: run plan_redactions over REPORT for COUNT staged files (default 2).
plan() {
	local report=$1 count=${2:-2}
	run bash -c 'source "$1" && plan_redactions "$2" "$3" "$4"' _ "$PI_SHARE" "$SCAN" "$count" "$report"
}

b64() {
	printf '%s' "$1" | base64 -w0
}

# Report rows written by the sandbox snippets: "row FILE LINE SECRET MATCH" appends a 6-field row.
# shellcheck disable=SC2016 # expanded inside the sandbox
ROW='row() { printf "@SCAN@/%s\t%s\t%s\t0\t%s\t%s\n" "$1" "$2" "$2" "$(printf "%s" "$3" | base64 -w0)" "$(printf "%s" "$4" | base64 -w0)" >>/mnt/stub/gitleaks.out; }
'

@test "redact_line turns password = p4ssw0rd into password = [REDACTED]" {
	redact "password = p4ssw0rd" p4ssw0rd "password = p4ssw0rd"
	[ "$status" -eq 0 ]
	[ "$output" = "password = [REDACTED]" ]
}

@test "redact_line replaces every occurrence of a secret on the line" {
	redact "a=s3cr3t b=s3cr3t c" s3cr3t "a=s3cr3t"
	[ "$status" -eq 0 ]
	[ "$output" = "a=[REDACTED] b=[REDACTED] c" ]
}

@test "redact_line covers overlapping occurrences" {
	redact "xaaaaaay" aaaa aaaa
	[ "$status" -eq 0 ]
	[ "$output" = "x[REDACTED]y" ]
}

@test "redact_line merges two secrets that overlap" {
	redact "k=XYZABC;" XYZABC "k=XYZABC" ABC ABC
	[ "$status" -eq 0 ]
	[ "$output" = "k=[REDACTED];" ]
}

@test "redact_line keeps sed and glob characters in the rest of the line verbatim" {
	redact 'a&b\c/d*e[f k=SECRET? x' SECRET? 'k=SECRET?'
	[ "$status" -eq 0 ]
	[ "$output" = 'a&b\c/d*e[f k=[REDACTED] x' ]
}

@test "redact_line fails when a secret is not on the line, a secret is empty, or a match does not contain its secret" {
	redact "password = other" p4ssw0rd p4ssw0rd
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	redact "password = p4ssw0rd" "" "password = p4ssw0rd"
	[ "$status" -eq 1 ]
	redact "password = p4ssw0rd" p4ssw0rd "token = p4ssw0rd"
	[ "$status" -eq 1 ]
	redact "password = p4ssw0rd" p4ssw0rd "p4ss"
	[ "$status" -eq 1 ]
}

@test "plan_redactions passes a single-line, untagged finding through with its secret and match" {
	plan "$(printf '%s/1\t7\t7\t0\t%s\t%s\n' "$SCAN" "$(b64 p4ssw0rd)" "$(b64 'pw = p4ssw0rd')")"
	[ "$status" -eq 0 ]
	[ "$output" = "1 7 7 $(b64 p4ssw0rd) $(b64 'pw = p4ssw0rd')" ]
}

@test "plan_redactions keeps two different secrets on one line as two rows, and drops an exact duplicate" {
	local a b
	a=$(printf '%s/0\t3\t3\t0\t%s\t%s' "$SCAN" "$(b64 one1)" "$(b64 one1)")
	b=$(printf '%s/0\t3\t3\t0\t%s\t%s' "$SCAN" "$(b64 two2)" "$(b64 two2)")
	plan "$(printf '%s\n%s\n%s\n' "$a" "$b" "$a")"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
	[[ $output == *"0 3 3 $(b64 one1) $(b64 one1)"* ]]
	[[ $output == *"0 3 3 $(b64 two2) $(b64 two2)"* ]]
}

@test "plan_redactions makes a multi-line, a tagged, or an empty-secret finding a whole-line row" {
	plan "$(printf '%s/0\t3\t4\t0\t%s\t%s\n' "$SCAN" "$(b64 abc)" "$(b64 abc)")"
	[ "$status" -eq 0 ]
	[ "$output" = "0 3 4" ]
	plan "$(printf '%s/0\t3\t3\t2\t%s\t%s\n' "$SCAN" "$(b64 abc)" "$(b64 abc)")"
	[ "$status" -eq 0 ]
	[ "$output" = "0 3 3" ]
	plan "$(printf '%s/0\t3\t3\t0\t\t%s\n' "$SCAN" "$(b64 abc)")"
	[ "$status" -eq 0 ]
	[ "$output" = "0 3 3" ]
}

@test "plan_redactions fails on a 4- or 5-field row, a non-numeric tag count, and a secret that is not base64" {
	local line
	for line in "$SCAN/0\t1\t1\t0" "$SCAN/0\t1\t1\t0\tYWJj" "$SCAN/0\t1\t1\tx\tYWJj\tYWJj" \
		"$SCAN/0\t1\t1\t0\ta b\tYWJj" "$SCAN/0\t1\t1\t0\tYWJj\tYW=Jj"; do
		plan "$(printf '%b' "$line")"
		[ "$status" -eq 1 ]
		[[ $output == *"unexpected gitleaks report line"* ]]
	done
}

@test "sudo: a finding with its secret replaces only the secret, and the copy stays root-owned with tester read access" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/conf "user = admin
password = p4ssw0rd
end"
		row 0 2 p4ssw0rd "password = p4ssw0rd"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "user = admin
password = [REDACTED]
end" ]
		[ "$(stat -c "%u:%g %a" "$copy")" = "0:0 440" ]
		[[ $err == *"gitleaks redacted 1 line(s) in 1 file(s)"* ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: two findings on one line replace both secrets, and the line is counted once" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/conf "a=AAAA1111 b=BBBB2222 c"
		row 0 1 AAAA1111 a=AAAA1111
		row 0 1 BBBB2222 b=BBBB2222
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "a=[REDACTED] b=[REDACTED] c" ]
		[[ $err == *"gitleaks redacted 1 line(s) in 1 file(s)"* ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a whole-line finding on the same line wins over a partial one" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/conf "x
pw = p4ssw0rd tail
y"
		row 0 2 p4ssw0rd "pw = p4ssw0rd"
		printf "@SCAN@/0\t1\t2\n" >>/mnt/stub/gitleaks.out
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "[REDACTED]
[REDACTED]
y" ]
		[[ $err == *"gitleaks redacted 2 line(s) in 1 file(s)"* ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a secret not on its line, and a line holding a NUL byte, redact the whole line" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/a "one
pw = other
three"
		row 0 2 p4ssw0rd "pw = p4ssw0rd"
		share -- /mnt/data/a
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "one
[REDACTED]
three" ]
		rm -f /mnt/stub/gitleaks.out
		printf "x\npw = p4ssw0rd\000hidden\nz\n" >/mnt/data/b
		chmod 0600 /mnt/data/b
		row 0 2 p4ssw0rd "pw = p4ssw0rd"
		share -- /mnt/data/b
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(sed -n 2p "$copy")" = "[REDACTED]" ]
		[ "$(sed -n 3p "$copy")" = "z" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: & \\ and / around the secret survive the sed rewrite" {
	load sudo-sandbox
	require_sandbox
	run sandbox "$ROW"'
		make_file /mnt/data/conf "a&b\\c/d k=S3cr&t/\\x e&f"
		row 0 1 "S3cr&t/\\x" "k=S3cr&t/\\x"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(cat "$copy")" = "a&b\\c/d k=[REDACTED] e&f" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "the report template, run through the installed gitleaks, reports a stripe key's line, tag count 0, secret and match" {
	local gitleaks
	gitleaks=$(command -v gitleaks) || skip "gitleaks is not installed"
	mkdir -p "$BATS_TEST_TMPDIR/scan"
	printf 'first\nToken  sk_live_51HxQ2aBcDeFgHiJkLmNoPqRsT\n' >"$BATS_TEST_TMPDIR/scan/0"
	bash -c 'source "$1" && printf "%s" "$REPORT_TEMPLATE"' _ "$PI_SHARE" >"$BATS_TEST_TMPDIR/template"
	run "$gitleaks" dir --no-banner --no-color --log-level error --exit-code 3 \
		--report-format template --report-template "$BATS_TEST_TMPDIR/template" --report-path - \
		-- "$BATS_TEST_TMPDIR/scan"
	[ "$status" -eq 3 ]
	local secret
	secret=$(b64 sk_live_51HxQ2aBcDeFgHiJkLmNoPqRsT)
	[ "$output" = "$(printf '%s\t2\t2\t0\t%s\t%s' "$BATS_TEST_TMPDIR/scan/0" "$secret" "$secret")" ]
}
