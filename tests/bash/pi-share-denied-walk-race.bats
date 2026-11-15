#!/usr/bin/env bats
# findutils before 4.11 still reports some entries that vanish mid-walk as "No such file or
# directory" under -ignore_readdir_race, and exits 1. denied_identities tolerates exactly that and
# fails closed on anything else. A stub find stands in for findutils 4.9, deterministically.

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

# fake_find RC STDERR-LINES...: a find that prints one record in the -printf format it is given,
# then the STDERR-LINES on stderr, and exits RC. It logs its LC_ALL to $STUBS/find.env.
fake_find() {
	local rc=$1 line
	shift
	{
		printf '#!/bin/bash\n'
		printf 'echo "LC_ALL=${LC_ALL-unset}" >>%q\n' "$STUBS/find.env"
		# shellcheck disable=SC2016 # expanded by the stub
		printf '%s\n' 'root=$2 fmt=""' \
			'while (($#)); do [[ $1 == -printf ]] && fmt=$2; shift; done' \
			'if [[ $fmt == *%p* ]]; then printf "%s/key-1\0" "$root"; printf "7:42\0"; else printf "7:42\n"; fi'
		for line in "$@"; do
			printf 'printf "%%s\\n" %q >&2\n' "${line}"
		done
		printf 'exit %s\n' "${rc}"
	} >"$STUBS/find"
	chmod +x "$STUBS/find"
}

@test "denied_identities succeeds and prints the identities when find exits 1 having reported only No such file or directory lines, for a literal entry, a pattern entry and type d" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit" "$t/pat"
	fake_find 1 "find: '$t/lit/d19': No such file or directory" "find: '$t/lit/d18': No such file or directory"
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/lit"
	[ "$status" -eq 0 ]
	[[ $output == *"7:42"* ]]
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/pat/key-*"
	[ "$status" -eq 0 ]
	[[ $output == *"7:42"* ]]
	walk 'PATH="$STUBS:$PATH" denied_identities d' "$t/lit"
	[ "$status" -eq 0 ]
	[ "$output" = "7:42" ]
}

@test "denied_identities fails with failed (find exit 1) when find exits 1 with a Permission denied line" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit"
	fake_find 1 "find: '$t/lit/secret': Permission denied"
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/lit"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/lit failed (find exit 1)"* ]]
}

@test "denied_identities fails when find exits 1 with ENOENT lines and one Permission denied line" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit" "$t/pat"
	fake_find 1 "find: '$t/lit/a': No such file or directory" "find: '$t/lit/b': Permission denied" \
		"find: '$t/lit/c': No such file or directory"
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/lit"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/lit failed (find exit 1)"* ]]
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/pat/key-*"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/pat failed (find exit 1)"* ]]
}

@test "denied_identities fails when a Permission denied line quotes a name ending in : No such file or directory" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit"
	fake_find 1 "find: '$t/lit/x: No such file or directory': Permission denied"
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/lit"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/lit failed (find exit 1)"* ]]
}

@test "denied_identities fails with failed (find exit 2) when find exits 2 with only ENOENT lines" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit"
	fake_find 2 "find: '$t/lit/a': No such file or directory"
	walk 'PATH="$STUBS:$PATH" denied_identities' "$t/lit"
	[ "$status" -eq 1 ]
	[[ $output == *"never-share walk of $t/lit failed (find exit 2)"* ]]
}

@test "denied_identities runs find with LC_ALL=C even when the caller has LC_ALL and LANG set to another locale" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit" "$t/pat"
	fake_find 0
	walk 'LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 PATH="$STUBS:$PATH" denied_identities' "$t/lit" "$t/pat/key-*"
	[ "$status" -eq 0 ]
	[ "$(cat "$STUBS/find.env")" = "$(printf 'LC_ALL=C\nLC_ALL=C')" ]
}

@test "denied_identities prints nothing of find's stderr" {
	local t=$BATS_TEST_TMPDIR
	mkdir -p "$t/lit"
	fake_find 1 "find: '$t/lit/MARK-gone': No such file or directory"
	walk 'PATH="$STUBS:$PATH" denied_identities 2>&1' "$t/lit"
	[ "$status" -eq 0 ]
	[[ $output != *MARK* ]]
	fake_find 1 "find: '$t/lit/MARK-denied': Permission denied"
	walk 'PATH="$STUBS:$PATH" denied_identities 2>&1' "$t/lit"
	[ "$status" -eq 1 ]
	[[ $output != *MARK* ]]
}
