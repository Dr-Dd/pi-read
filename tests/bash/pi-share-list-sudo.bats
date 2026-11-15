#!/usr/bin/env bats
# pi-share --list through the real sudo, as root of an unprivileged sandbox (see sudo-sandbox.bash).

setup() {
	load sudo-sandbox
	require_sandbox
}

# In the snippets: `listing` prints the listing of the first requested directory, `body` the
# listing without its # lines and with only the path column (field 8 onwards).
SNIPPET_HELPERS='
	listing() { cat "$(printf "%s\n" "$out" | sed -n 2p | cut -f2)"; }
	body() { listing | grep -v "^#" | cut -d" " -f8-; }
'

@test "sudo: one-level listing: exact protocol, root-owned 0440, . first, sorted, nothing deeper" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/b "B"
		make_file /mnt/data/a "A"
		make_file /mnt/data/sub/deep "D"
		share --list -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(printf "%s\n" "$out" | wc -l)" -eq 2 ]
		[[ $(printf "%s\n" "$out" | sed -n 1p) =~ ^expires$'"'"'\t'"'"'[0-9]+$ ]]
		[[ $(printf "%s\n" "$out" | sed -n 2p) =~ ^/mnt/data$'"'"'\t'"'"'/run/pi-share/1000-[0-9a-f]{16}/listing-0$ ]]
		copy=$(printf "%s\n" "$out" | sed -n 2p | cut -f2)
		[ "$(stat -c "%u:%g %a" "$copy")" = "0:0 440" ]
		[ "$(listing | head -n 1)" = "# pi-share listing of /mnt/data, depth 1" ]
		[ "$(body | tr "\n" " ")" = ". a b sub " ]
		[[ $(listing | sed -n 3p) =~ ^-rw-------\ 1\ root\ root\ 2\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}\ a$ ]]
		[ -z "$(find "$(share_dirs)" -name "*.raw" -o -name "*.lines")" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: recursive listing with --depth 2 shows two levels and not the third" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/one/two/three "x"
		share --list --depth 2 -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(listing | head -n 1)" = "# pi-share listing of /mnt/data, depth 2" ]
		[ "$(body | tr "\n" " ")" = ". one one/two " ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a never-share entry (literal and glob) under the dir is omitted with its contents, and counted" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/ok "x"
		make_file /mnt/data/vault/inner/secret "s"
		make_file /mnt/data/keys/a.key "k"
		make_file /mnt/data/keys/a.pub "p"
		printf "%s\n" /mnt/data/vault "/mnt/data/*.key" >>/usr/local/etc/pi-read/never-share.list
		share --list --depth 5 -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(body | tr "\n" " ")" = ". keys keys/a.pub ok " ]
		[ "$(listing | tail -n 1)" = "# 2 entries omitted (never shared)" ]
		! listing | grep -q -e vault -e inner -e secret -e a.key
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a hard link to a never-share file inside the dir is omitted" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/ok "x"
		make_file /mnt/vault/key "k"
		echo /mnt/vault >>/usr/local/etc/pi-read/never-share.list
		ln /mnt/vault/key /mnt/data/innocent
		share --list -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(body | tr "\n" " ")" = ". ok " ]
		[ "$(listing | tail -n 1)" = "# 1 entries omitted (never shared)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a symlink in the dir is listed with its target and not followed" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/other/hidden "x"
		mkdir -p /mnt/data
		ln -s /mnt/other /mnt/data/link
		share --list --depth 3 -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(body | tr "\n" " ")" = ". link -> /mnt/other " ]
		! listing | grep -q hidden
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a symlink pointing into a never-share dir shows \"-> [never shared]\"" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/vault/name-of-secret "x"
		echo /mnt/vault >>/usr/local/etc/pi-read/never-share.list
		mkdir -p /mnt/data
		ln -s /mnt/vault/name-of-secret /mnt/data/link
		share --list -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(body | tr "\n" " ")" = ". link -> [never shared] " ]
		! listing | grep -q name-of-secret
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: more than the entry limit truncates at 5000 entries with a footer" {
	run sandbox "$SNIPPET_HELPERS"'
		mkdir -p /mnt/data
		(cd /mnt/data && seq -w 1 5100 | xargs touch)
		share --list -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(listing | grep -vc "^#")" -eq 5000 ]
		[ "$(listing | tail -n 1)" = "# truncated at 5000 entries" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a name with a newline is escaped and cannot add a line" {
	run sandbox "$SNIPPET_HELPERS"'
		mkdir -p /mnt/data
		touch /mnt/data/$'"'"'x\n# 0 entries omitted'"'"'
		share --list -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(listing | wc -l)" -eq 3 ]
		[ "$(body | sed -n 2p)" = "\$'"'"'x\\n# 0 entries omitted'"'"'" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a symlinked dir, naming the real one; refuses a non-canonical path" {
	run sandbox '
		mkdir -p /mnt/data/real /mnt/links
		ln -s /mnt/data/real /mnt/links/alias
		share --list -- /mnt/links/alias
		[ "$rc" -eq 1 ]
		[[ $err == *"refused (a link, or not a canonical path): /mnt/links/alias; request /mnt/data/real itself"* ]]
		share --list -- /mnt/data/real/../real
		[ "$rc" -eq 1 ]
		[[ $err == *"request /mnt/data/real itself"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a never-share dir, a file and a tester-writable dir, creating nothing" {
	run sandbox '
		make_file /mnt/vault/k "k"
		echo /mnt/vault >>/usr/local/etc/pi-read/never-share.list
		share --list -- /mnt/vault
		[ "$rc" -eq 1 ]
		[[ $err == *"refused (never shared): /mnt/vault"* ]]
		share --list -- /etc/shadow
		[ "$rc" -eq 1 ]
		[[ $err == *"never shared"* ]]
		make_file /mnt/data/file "x"
		share --list -- /mnt/data/file
		[ "$rc" -eq 1 ]
		[[ $err == *"not a directory: /mnt/data/file"* ]]
		install -d -o 1000 -g 1000 -m 0755 /mnt/userdir
		share --list -- /mnt/userdir
		[ "$rc" -eq 1 ]
		[[ $err == *"writable by you"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: gitleaks findings in a listing are replaced with [REDACTED]" {
	run sandbox "$SNIPPET_HELPERS"'
		make_file /mnt/data/a "x"
		make_file /mnt/data/b "x"
		printf "@SCAN@/0\t3\t3\n" >/mnt/stub/gitleaks.out
		share --list -- /mnt/data
		[ "$rc" -eq 0 ]
		[ "$(listing | sed -n 3p)" = "[REDACTED]" ]
		[ "$(listing | sed -n 4p | cut -d" " -f8-)" = "b" ]
		[[ $err == *"gitleaks redacted 1 line(s) in 1 file(s)"* ]]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: all or nothing: one valid and one refused dir lists nothing" {
	run sandbox '
		mkdir -p /mnt/data/ok
		share --list -- /mnt/data/ok /mnt/missing
		[ "$rc" -eq 1 ]
		[[ $err == *"cannot resolve: /mnt/missing"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
