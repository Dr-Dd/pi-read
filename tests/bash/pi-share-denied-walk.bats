#!/usr/bin/env bats
# The never-share walk (denied_identities) fails closed, with a timeout per entry, tolerates files
# vanishing mid-walk, and is skipped for file requests when no requested file has a second link
# and none is on a filesystem a bind mount could also reach.

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
	export STUBS="$BATS_TEST_TMPDIR/stubs"
	mkdir -p "$STUBS"
}

# Run a snippet with pi-share sourced and DENIED_ENTRIES set to the remaining arguments.
walk() {
	local snippet=$1
	shift
	run bash -c 'source "$1" && snippet=$2 && shift 2 && DENIED_ENTRIES=("$@") && eval "$snippet"' _ \
		"$PI_SHARE" "$snippet" "$@"
}

# stub NAME BODY: put an executable sh script NAME first on PATH.
stub() {
	printf '#!/bin/sh\n%s\n' "$2" >"$STUBS/$1"
	chmod +x "$STUBS/$1"
}

@test "denied_identities prints identities and succeeds for existing literal and pattern entries" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit" "$t/pat"
	echo a >"$t/lit/a"
	echo b >"$t/pat/key-1"
	echo c >"$t/pat/other"
	walk 'denied_identities' "$t/lit" "$t/pat/key-*"
	[ "$status" -eq 0 ]
	[[ $output == *"$(stat -c '%d:%i' "$t/lit/a")"* ]]
	[[ $output == *"$(stat -c '%d:%i' "$t/pat/key-1")"* ]]
	[[ $output != *"$(stat -c '%d:%i' "$t/pat/other")"* ]]
}

@test "denied_identities skips a literal entry and a pattern base that do not exist" {
	local t=$BATS_TEST_TMPDIR
	local swap
	# Type f also prints the swap files of this machine: compare with no entries at all.
	walk 'denied_identities'
	swap=$output
	walk 'denied_identities' "$t/missing" "$t/nobase/key-*"
	[ "$status" -eq 0 ]
	[ "$output" = "$swap" ]
	walk 'denied_identities d' "$t/missing" "$t/nobase/key-*"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "denied_identities fails, naming the root and the status, when find fails on a literal entry" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit"
	stub find 'echo 1:1; exit 2'
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/lit"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/lit failed (find exit 2)"* ]]
}

@test "denied_identities fails, naming the base, when find fails on a pattern entry" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/pat"
	stub find 'exit 1'
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/pat/key-*"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/pat failed (find exit 1)"* ]]
}

@test "denied_identities fails with timed out on 124 and runs find under DENIED_WALK_TIMEOUT" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit" "$t/pat"
	stub timeout "echo \"\$*\" >>'$t/timeout.log'; exit 124"
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/lit"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/lit timed out after 30 s"* ]]
	grep -q -- "^-k 5 30 find -H $t/lit " "$t/timeout.log"
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/pat/key-*"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/pat timed out"* ]]
}

@test "denied_identities d also fails on a find failure" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit"
	stub find 'exit 1'
	walk 'PATH="$STUBS:$PATH" denied_identities d' "$t/lit"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/lit failed"* ]]
}

@test "denied_identities succeeds while files and directories vanish during the walk" {
	local t=$BATS_TEST_TMPDIR real i
	real=$(type -P find)
	# The real find, with an expression added after -ignore_readdir_race that empties the root at the
	# first file it visits, so the rest of the walk meets entries that are gone. STRIP=1 drops
	# -ignore_readdir_race itself, as a control that the deletion really happens mid-walk.
	cat >"$STUBS/find" <<-EOF
		#!/bin/bash
		args=()
		for a in "\$@"; do
			if [[ \$a == -ignore_readdir_race ]]; then
				[[ \${STRIP:-0} == 1 ]] || args+=("\$a")
				args+=( \( -type f -exec sh -c 'rm -rf -- "\$1"/*' _ "\$VICTIM" \; -false \) -o )
				continue
			fi
			args+=("\$a")
		done
		exec "$real" "\${args[@]}"
	EOF
	chmod +x "$STUBS/find"
	fill() {
		rm -rf "$t/root"
		mkdir -p "$t/root"
		for i in $(seq 1 20); do
			mkdir -p "$t/root/d$i/x"
			: >"$t/root/d$i/x/f"
		done
	}
	export VICTIM="$t/root"
	fill
	STRIP=1 walk 'PATH="$STUBS:$PATH" denied_identities' "$t/root"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/root failed"* ]]
	fill
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/root"
	[ "$status" -eq 0 ]
	[ -z "$(ls -A "$t/root")" ]
	fill
	walk 'PATH="$STUBS:$PATH" denied_identities d' "$t/root"
	[ "$status" -eq 0 ]
	fill
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/root/d*/x"
	[ "$status" -eq 0 ]
	[ -d "$t/root" ]
}

@test "on_shared_mount: a tmpfs mounted once is not shared; bind mounts and a second mount are" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		source /mnt/bin/pi-share
		set +e
		mkdir -p /mnt/t /mnt/u /mnt/v
		mount -t tmpfs -o mode=0755 tmpfs /mnt/t
		mkdir /mnt/t/a /mnt/t/b
		echo s >/mnt/t/a/s
		: >/mnt/t/b/x
		on_shared_mount /mnt/t/a/s && exit 11
		mount --bind /mnt/t/a/s /mnt/t/b/x
		on_shared_mount /mnt/t/b/x || exit 12
		umount /mnt/t/b/x
		on_shared_mount /mnt/t/a/s && exit 13
		mount --bind /mnt/t/a /mnt/u
		on_shared_mount /mnt/u/s || exit 14
		umount /mnt/u
		mount --bind /mnt/t /mnt/v
		on_shared_mount /mnt/t/a/s || exit 15
		exit 0
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: one-link files bind-mounted from never-share files or dirs are refused as linked" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		echo "/mnt/secret" >>/usr/local/etc/pi-read/never-share.list
		mkdir -p -m 0755 /mnt/secret /mnt/data /mnt/view
		mount -t tmpfs -o mode=0755 tmpfs /mnt/secret
		make_file /mnt/secret/key "KEY" 0600
		mkdir -m 0755 /mnt/secret/dir
		make_file /mnt/secret/dir/conf "CONF" 0600
		make_file /mnt/data/alias "x" 0600
		mount --bind /mnt/secret/key /mnt/data/alias
		[ "$(stat -c %h /mnt/data/alias)" -eq 1 ]
		share -- /mnt/data/alias
		[ "$rc" -eq 1 ]
		[[ $err == *"refused (never shared, linked): /mnt/data/alias"* ]]
		mount --bind /mnt/secret/dir /mnt/view
		share -- /mnt/view/conf
		[ "$rc" -eq 1 ]
		[[ $err == *"refused (never shared, linked): /mnt/view/conf"* ]]
		[ ! -d /run/pi-share ] || [ -z "$(ls -A /run/pi-share)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "needs_link_walk fails for one-link files, succeeds for a second link and an unreadable path" {
	local t=$BATS_TEST_TMPDIR
	echo a >"$t/a"
	echo b >"$t/b"
	walk 'needs_link_walk "$@"' "$t/a" "$t/b"
	[ "$status" -eq 1 ]
	ln "$t/b" "$t/b-link"
	walk 'needs_link_walk "$@"' "$t/a" "$t/b"
	[ "$status" -eq 0 ]
	walk 'needs_link_walk "$@"' "$t/a" "$t/missing"
	[ "$status" -eq 0 ]
}

@test "check_not_linked refuses a listed identity and accepts the others" {
	local t=$BATS_TEST_TMPDIR denied
	echo a >"$t/a"
	echo b >"$t/b"
	denied=$(printf '1:1\n%s\n' "$(stat -c '%d:%i' "$t/b")")
	run bash -c 'source "$1" && check_not_linked "$2" "$3" "$4"' _ "$PI_SHARE" "$denied" "$t/a" "$t/b"
	[ "$status" -eq 1 ]
	[[ $output == *"refused (never shared, linked): $t/b"* ]]
	run bash -c 'source "$1" && check_not_linked "$2" "$3"' _ "$PI_SHARE" "$denied" "$t/a"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "sudo: one-link files skip the walk; a file with a second link walks once" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		source /mnt/bin/pi-share
		mkdir -p -m 0755 /mnt/data
		mount -t tmpfs -o mode=0755 tmpfs /mnt/data
		make_file /mnt/data/a "A" 0600
		make_file /mnt/data/b "B" 0600
		calls=/mnt/log/denied-calls
		: >"$calls"
		denied_identities() {
			echo call >>"$calls"
			printf "999999:999999\n"
		}
		export SUDO_UID=1000 SUDO_GID=1000
		(main -- /mnt/data/a /mnt/data/b >/mnt/log/out)
		[ "$(wc -l <"$calls")" -eq 0 ]
		[ "$(tail -n +2 /mnt/log/out | cut -f1 | tr "\n" " ")" = "/mnt/data/a /mnt/data/b " ]
		ln /mnt/data/b /mnt/data/b-link
		(main -- /mnt/data/a /mnt/data/b >/mnt/log/out)
		[ "$(wc -l <"$calls")" -eq 1 ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a failing walk refuses a hard-linked file, creating nothing; a one-link file is shared" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		# Only the never-share walk fails: grant_read runs find on the share dir, so that goes to the real find.
		printf "%s\n" "#!/bin/sh" "for a; do case \$a in /run/pi-share/*) exec /usr/bin/find \"\$@\";; esac; done" "exit 1" >/mnt/stub/find
		install -o 0 -g 0 -m 0755 /mnt/stub/find /usr/local/bin/find
		make_file /mnt/data/linked "L" 0600
		ln /mnt/data/linked /mnt/data/linked-2
		share -- /mnt/data/linked
		[ "$rc" -eq 1 ]
		[[ $err == *"never-share walk of"*"failed (find exit 1)"* ]]
		[[ $err == *"nothing shared"* ]]
		[ ! -d /run/pi-share ] || [ -z "$(ls -A /run/pi-share)" ]
		[ -z "$(stub_log systemd-run)" ]
		mkdir -p -m 0755 /mnt/one
		mount -t tmpfs -o mode=0755 tmpfs /mnt/one
		make_file /mnt/one/single "S" 0600
		share -- /mnt/one/single
		[ "$rc" -eq 0 ]
		[ -n "$(ls -A /run/pi-share)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: a failing walk refuses a listing, creating nothing" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		printf "%s\n" "#!/bin/sh" "exit 1" >/mnt/stub/find
		install -o 0 -g 0 -m 0755 /mnt/stub/find /usr/local/bin/find
		mkdir -p -m 0755 /mnt/data/dir
		share --list -- /mnt/data/dir
		[ "$rc" -eq 1 ]
		[[ $err == *"never-share walk of"*"failed (find exit 1)"* ]]
		[[ $err == *"nothing shared"* ]]
		[ ! -d /run/pi-share ] || [ -z "$(ls -A /run/pi-share)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
