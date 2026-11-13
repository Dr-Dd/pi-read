#!/usr/bin/env bats
# A path with a control character would break pi-share's "requested<TAB>copy" output (and its own
# "resolved<TAB>size" protocol), so pi-share refuses it before anything is copied.

setup() {
	PI_SHARE="$BATS_TEST_DIRNAME/../../bin/pi-share"
}

@test "validate_path rejects a path with a tab, a newline or an escape character" {
	local c
	for c in $'\t' $'\n' $'\x1b'; do
		run bash -c 'source "$1" && validate_path "/etc/${2}hostname"' _ "$PI_SHARE" "$c"
		[ "$status" -ne 0 ]
		[[ $output == *"control character"* ]]
	done
}

@test "validate_path escapes the control character in its error" {
	run bash -c 'source "$1" && validate_path "/etc/${2}hostname"' _ "$PI_SHARE" $'\t'
	[ "$status" -ne 0 ]
	[[ $output == *"control character"* ]]
	[[ $output != *$'\t'* ]]
	[[ $output == *"\\t"* ]]
	[ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "sudo: refuses a symlink whose target has a tab" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		tab=$(printf "\t")
		make_file "/mnt/data/target${tab}here" "R"
		mkdir -m 0755 /mnt/links
		ln -s "/mnt/data/target${tab}here" /mnt/links/alias
		share -- /mnt/links/alias
		[ "$rc" -eq 1 ]
		[[ $err == *"control character"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "sudo: refuses a requested path whose own name has a newline" {
	load sudo-sandbox
	require_sandbox
	run sandbox '
		nl=$(printf "\nx")
		nl=${nl%x}
		make_file "/mnt/data/a${nl}b" "R"
		share -- "/mnt/data/a${nl}b"
		[ "$rc" -eq 1 ]
		[[ $err == *"control character"* ]]
		[ -z "$out" ]
		[ -z "$(share_dirs)" ]
		[ -z "$(stub_log systemd-run)" ]
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
