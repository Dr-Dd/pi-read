#!/usr/bin/env bats
# Directory listings (pi-share --list): argument parsing and the pieces of a listing line.

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
}

@test "--depth without --list exits 2; --depth 0, 11 and abc exit 2" {
	run "$PI_SHARE" --depth 2 -- /etc
	[ "$status" -eq 2 ]
	[[ $output == *"--depth needs --list"* ]]
	local d
	for d in 0 11 abc; do
		run "$PI_SHARE" --list --depth "$d" -- /etc
		[ "$status" -eq 2 ]
		[[ $output == *"invalid depth: $d"* ]]
	done
}

@test "list_prune_args yields a -path pair for each built-in and list entry" {
	run bash -c 'source "$1" && DENIED_ENTRIES=("/etc/shadow*" /root) && list_prune_args | tr "\0" "|"' _ "$PI_SHARE"
	[ "$status" -eq 0 ]
	[ "$output" = '-path|/proc|-o|-path|/proc/*|-o|-path|/sys|-o|-path|/sys/*|-o|-path|/dev|-o|-path|/dev/*|-o|-path|/etc/shadow*|-o|-path|/etc/shadow*/*|-o|-path|/root|-o|-path|/root/*|' ]
}

@test "format_entry escapes control characters in names and targets with %q" {
	run bash -c 'source "$1" && format_entry -rw-r--r-- 1 root root 3 "2026-01-01 00:00" f /x/"$2" "$2" ""' \
		_ "$PI_SHARE" $'a\nb'
	[ "$status" -eq 0 ]
	[ "$output" = "-rw-r--r-- 1 root root 3 2026-01-01 00:00 \$'a\\nb'" ]
	run bash -c 'source "$1" && format_entry lrwxrwxrwx 1 root root 3 "2026-01-01 00:00" l /x/l l "$2"' \
		_ "$PI_SHARE" $'t\x1b[2Jx'
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[ "$output" = "lrwxrwxrwx 1 root root 3 2026-01-01 00:00 l -> \$'t\\E[2Jx'" ]
}

@test "format_entry shows \"-> [never shared]\" for a link whose target, lexically or resolved, is denied" {
	mkdir -p "$BATS_TEST_TMPDIR/d" "$BATS_TEST_TMPDIR/secret"
	ln -s /etc/shadow "$BATS_TEST_TMPDIR/d/abs"
	ln -s ../../../../../../etc/gshadow "$BATS_TEST_TMPDIR/d/rel"
	# Through a link: the target names a harmless path, which itself leads to a denied one.
	ln -s "$BATS_TEST_TMPDIR/secret" "$BATS_TEST_TMPDIR/hop"
	ln -s "$BATS_TEST_TMPDIR/hop/key" "$BATS_TEST_TMPDIR/d/via"
	ln -s /etc/hostname "$BATS_TEST_TMPDIR/d/ok"
	local name target
	for name in abs rel via; do
		target=$(readlink "$BATS_TEST_TMPDIR/d/$name")
		run bash -c 'source "$1" && DENIED_ENTRIES+=("$2") &&
			format_entry lrwxrwxrwx 1 root root 1 "2026-01-01 00:00" l "$3" "$4" "$5"' \
			_ "$PI_SHARE" "$BATS_TEST_TMPDIR/secret" "$BATS_TEST_TMPDIR/d/$name" "$name" "$target"
		[ "$status" -eq 0 ]
		[ "$output" = "lrwxrwxrwx 1 root root 1 2026-01-01 00:00 $name -> [never shared]" ]
	done
	run bash -c 'source "$1" && format_entry lrwxrwxrwx 1 root root 1 "2026-01-01 00:00" l "$2" ok /etc/hostname' \
		_ "$PI_SHARE" "$BATS_TEST_TMPDIR/d/ok"
	[ "$output" = "lrwxrwxrwx 1 root root 1 2026-01-01 00:00 ok -> /etc/hostname" ]
}
