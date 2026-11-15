#!/usr/bin/env bats
# The gitleaks config built into pi-share: gitleaks' default rules plus rules for credentials
# written in config files (see SPEC.md). The real-gitleaks tests skip when gitleaks is absent and
# scan through pi-share's own run_gitleaks, exactly as a share does.

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
}

# scan TEXT: write TEXT as the only staged copy and run run_gitleaks over it with the installed
# gitleaks. Sets status, and output to one "LINE<TAB>SECRET" per finding (secret decoded), sorted.
scan() {
	local gitleaks base=$BATS_TEST_TMPDIR/base report
	gitleaks=$(command -v gitleaks) || skip "gitleaks is not installed"
	rm -rf -- "$base"
	mkdir -p -- "$base/scan"
	printf '%s\n' "$1" >"$base/scan/0"
	bash -c 'source "$1" && printf "%s" "$REPORT_TEMPLATE"' _ "$PI_SHARE" >"$base/template"
	status=0
	report=$(bash -c 'source "$1" && run_gitleaks "$2" "$3" "$4"' _ "$PI_SHARE" \
		"$base" "$base/scan" "$gitleaks") || status=$?
	output=$(printf '%s\n' "$report" | while IFS=$'\t' read -r _ start _ _ secret _; do
		[ -n "$start" ] || continue
		printf '%s\t%s\n' "$start" "$(printf '%s' "$secret" | base64 -d)"
	done | sort -n)
}

# expect LINE<TAB>SECRET...: output is exactly these rows, in this order.
expect() {
	local want
	want=$(printf '%s\n' "$@")
	if [ "$output" != "$want" ]; then
		printf 'want:\n%s\ngot:\n%s\n' "$want" "$output" >&2
		return 1
	fi
}

TICKET_LINES='password = p4ssw0rd
db_password=hunter2
requirepass foobared123
psk="correcthorsebattery"
bindpw S3cretBind!
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
auth_key = 0123456789abcdef0123456789abcdef'

MORE_LINES='  "password": "js0nPass",
DB_PASS='"'"'Tr0ub4dor&3'"'"'
Server=db;User Id=sa;Pwd=Conn5tr1ng;
'"'"'password'"'"' => '"'"'phpSecret'"'"'
masterauth "redisMaster"
wpa_passphrase=hostapdpass
db_password := "goS3cret"
SMTP_PASS=mailS3cret
	secret "c2VjcmV0S2V5";
<password>xmlSecret1</password>
<password type="plain">attrS3cret</password>'

URL_LINES='DATABASE_URL=postgres://app:urlS3cret@db:5432/app
postgres://app:p!ss$w0rd@db/app
postgres://app:pa:ss@db/app
postgres://app:p@ss@db/app
postgres://app:pass@word@db/app
mysql://root:12345678@db/x'

@test "the installed gitleaks flags each of the ticket's config lines, reporting exactly the value" {
	scan "$TICKET_LINES"
	[ "$status" -eq 3 ]
	expect $'1\tp4ssw0rd' $'2\thunter2' $'3\tfoobared123' $'4\tcorrecthorsebattery' \
		$'5\tS3cretBind!' $'6\twJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' \
		$'7\t0123456789abcdef0123456789abcdef'
}

@test "the installed gitleaks flags JSON, quoted, connection-string, PHP, Go, SMTP_PASS, secret \"...\";, Redis, hostapd and XML credentials" {
	scan "$MORE_LINES"
	[ "$status" -eq 3 ]
	expect $'1\tjs0nPass' $'2\tTr0ub4dor&3' $'3\tConn5tr1ng;' $'4\tphpSecret' $'5\tredisMaster' \
		$'6\thostapdpass' $'7\tgoS3cret' $'8\tmailS3cret' $'9\tc2VjcmV0S2V5' $'10\txmlSecret1' \
		$'11\tattrS3cret'
}

@test "the installed gitleaks flags URL passwords whole: plain, with sub-delims, a colon, a raw @, and all digits" {
	scan "$URL_LINES"
	[ "$status" -eq 3 ]
	expect $'1\turlS3cret' $'2\tp!ss$w0rd' $'3\tpa:ss' $'4\tp@ss' $'5\tpass@word' $'6\t12345678'
}

@test "the installed gitleaks flags nothing in ordinary config and log lines, placeholders, short, letterless or boolean values, id keys, indirect references and [REDACTED]" {
	scan 'PasswordAuthentication no
passwd:         files systemd
shadow:         files
passwd: compat [NOTFOUND=return] files
passwd: files # local only
password	required	pam_unix.so sha512 shadow try_first_pass
Failed password for invalid user root from 10.0.0.1 port 22 ssh2
Defaults passwd_timeout=0
use_password = yes
encrypt passwords = yes
password = ${DB_PASSWORD}
password = $DB_PASSWORD
password: "{{ vault_db_password }}"
password = <your password>
password = ********
password_max_age = 90000
password = abc
password = "abc"
"password": "on",
'"'"'password'"'"' => '"'"'***'"'"',
"password": true,
'"'"'password'"'"' => false,
password: ${DB_PASS},
password := "abc"
pwd := $X
client_secret_id = abcdef12
secret = get_secret_key()
password = os.environ["DB_PASS"]
'"'"'password'"'"' => getenv('"'"'X'"'"'),
"password": null,
'"'"'secret'"'"' => null,
passive_mode = active
pass_through = enabled
psk_mode = wpa2psk
bypass = abcdefgh
password_file = /run/secrets/db
token_type = bearer
proxy_pass http://backend;
https://example.com/path
http://host:8080/x@y
ssh://git@github.com:22/x
mailto:user@example.com
postgres://app:$DBPASS@db/app
postgres://app:${DBPASS}@db/app
requirepass ${REDIS_PASS}
requirepass $REDIS_PASS
fastcgi_pass_header "Authorization";
psk_mode "wpa2";
password = [REDACTED]
"password": "[REDACTED]",
requirepass [REDACTED]
postgres://app:[REDACTED]@db/app
<password>[REDACTED]</password>'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "the installed gitleaks still flags a stripe key with the built-in config" {
	scan 'Token  sk_live_51HxQ2aBcDeFgHiJkLmNoPqRsT'
	[ "$status" -eq 3 ]
	expect $'1\tsk_live_51HxQ2aBcDeFgHiJkLmNoPqRsT'
}

@test "each flagged line, after redact_line of its secret, is flagged by nothing on the re-scan" {
	local line secret redacted all="" first=""
	scan "$TICKET_LINES
$MORE_LINES
$URL_LINES"
	[ "$status" -eq 3 ]
	local -a rows
	mapfile -t rows <<<"$output"
	[ "${#rows[@]}" -eq 24 ]
	local -a lines
	mapfile -t lines <<<"$TICKET_LINES
$MORE_LINES
$URL_LINES"
	for row in "${rows[@]}"; do
		secret=${row#*$'\t'}
		line=${lines[${row%%$'\t'*} - 1]}
		redacted=$(bash -c 'source "$1" && redact_line "$2" "$3" "$3"' _ "$PI_SHARE" "$line" "$secret")
		[[ $redacted == *"[REDACTED]"* && $redacted != *"$secret"* ]]
		[ -n "$first" ] || first=$redacted
		all+=$redacted$'\n'
	done
	[ "$first" = "password = [REDACTED]" ]
	scan "${all%$'\n'}"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "run_gitleaks writes the built-in config into BASE and passes --config BASE/gitleaks.toml" {
	local base=$BATS_TEST_TMPDIR/base
	mkdir -p "$base/scan" "$BATS_TEST_TMPDIR/bin"
	cat >"$BATS_TEST_TMPDIR/bin/gitleaks" <<-EOF
		#!/bin/sh
		echo "\$*" >"$BATS_TEST_TMPDIR/args"
		while [ \$# -gt 0 ]; do
			[ "\$1" = --config ] && cp -- "\$2" "$BATS_TEST_TMPDIR/config-seen"
			shift
		done
		exit 0
	EOF
	chmod 0755 "$BATS_TEST_TMPDIR/bin/gitleaks"
	run bash -c 'source "$1" && run_gitleaks "$2" "$3" "$4"' _ "$PI_SHARE" \
		"$base" "$base/scan" "$BATS_TEST_TMPDIR/bin/gitleaks"
	[ "$status" -eq 0 ]
	[[ $(cat "$BATS_TEST_TMPDIR/args") == *" --config $base/gitleaks.toml "* ]]
	bash -c 'source "$1" && printf "%s" "$GITLEAKS_CONFIG_TOML"' _ "$PI_SHARE" >"$BATS_TEST_TMPDIR/want"
	cmp -- "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/config-seen"
	grep -qx 'useDefault = true' "$BATS_TEST_TMPDIR/want"
}

@test "run_gitleaks returns 1 and says so in BASE/stderr when the config cannot be written, running nothing" {
	local base=$BATS_TEST_TMPDIR/base
	mkdir -p "$base/scan" "$BATS_TEST_TMPDIR/bin"
	# A directory where the config file goes cannot be written over.
	mkdir -p "$base/gitleaks.toml"
	printf '#!/bin/sh\ntouch "%s/ran"\nexit 0\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/gitleaks"
	chmod 0755 "$BATS_TEST_TMPDIR/bin/gitleaks"
	run bash -c 'source "$1" && run_gitleaks "$2" "$3" "$4"' _ "$PI_SHARE" \
		"$base" "$base/scan" "$BATS_TEST_TMPDIR/bin/gitleaks"
	[ "$status" -eq 1 ]
	[ "$(cat "$base/stderr")" = "could not write the gitleaks config" ]
	[ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "sudo: a share passes gitleaks --config in the .filter dir, outside the scan dir, which holds only the copies" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		make_file /mnt/data/conf "x"
		share -- /mnt/data/conf
		[ "$rc" -eq 0 ]
		args=$(stub_log gitleaks)
		[[ $args == *" --config /run/pi-share/"*"/.filter/gitleaks.toml "* ]]
		[[ $args != *"--config "*"/.filter/scan/"* ]]
		[ "$(stub_log gitleaks-scan)" = "0" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
