#!/usr/bin/env bats
# How long sudo remembers the password for pi-share, with install.sh's own sudoers rule and the
# real sudo, as root of an unprivileged sandbox (see sudo-sandbox.bash). PAM there logs each
# authentication instead of asking, so auth_count tells whether sudo asked.

setup() {
	load sudo-sandbox
	require_sandbox
}

# Run in every snippet. T runs sudo as tester (asking, through PAM, when it has to); N runs it with
# -n, which fails instead of asking. Both set rc.
helpers='
	set +e
	T() { setpriv --reuid 1000 --regid 1000 --init-groups -- sudo "$@" >/dev/null 2>&1; rc=$?; }
	N() { setpriv --reuid 1000 --regid 1000 --init-groups -- sudo -n "$@" >/dev/null 2>&1; rc=$?; }
	# probe prints what `sudo -n pi-share --probe` printed. sudo runs from this shell, not from a
	# $(...) subshell: the cache belongs to the process that runs sudo, as pi runs both.
	probe() {
		setpriv --reuid 1000 --regid 1000 --init-groups -- sudo -n /mnt/bin/pi-share --probe >/mnt/log/probe 2>/dev/null
		probed=$(cat /mnt/log/probe)
	}
	make_file /mnt/data/conf "x" 0600
'

@test "a second pi-share run from the same process within the timeout does not ask again" {
	run sandbox "$helpers"'
		use_password_rule 30
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		[ "$(auth_count)" -eq 1 ] || exit 1
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		[ "$(auth_count)" -eq 1 ] || exit 1
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "the probe succeeds only while the password is remembered" {
	run sandbox "$helpers"'
		use_password_rule 30
		probe; [ -z "$probed" ] || exit 1
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		probe; [ "$probed" = "pi-share: probe" ] || exit 1
		[ "$(auth_count)" -eq 1 ] || exit 1
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "pi-share asks again once the timeout has passed" {
	run sandbox "$helpers"'
		use_password_rule 3
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		probe; [ "$probed" = "pi-share: probe" ] || exit 1
		sleep 4
		probe; [ -z "$probed" ] || exit 1
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		[ "$(auth_count)" -eq 2 ] || exit 1
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "with timeout 0 pi-share asks every time and the probe never succeeds" {
	run sandbox "$helpers"'
		use_password_rule 0
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		probe; [ -z "$probed" ] || exit 1
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		[ "$(auth_count)" -eq 2 ] || exit 1
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a password typed for pi-share does not let another command run without one, and the reverse" {
	run sandbox "$helpers"'
		use_password_rule 30
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		N /usr/bin/true; [ "$rc" -ne 0 ] || exit 1
		T /usr/bin/true; [ "$rc" -eq 0 ] || exit 1
		[ "$(auth_count)" -eq 2 ] || exit 1
		# A fresh process, so its pi-share cache is empty, while the normal one is set.
		bash -c "$(declare -f T N); T /usr/bin/true; N /usr/bin/true; [ \$rc -eq 0 ] || exit 1; N /mnt/bin/pi-share --probe; [ \$rc -ne 0 ]" || exit 1
		[ "$(auth_count)" -eq 3 ] || exit 1
	'
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a pi-share run from another process, or another session, asks again" {
	run sandbox "$helpers"'
		use_password_rule 30
		T /mnt/bin/pi-share -- /mnt/data/conf; [ "$rc" -eq 0 ] || exit 1
		N /mnt/bin/pi-share --probe; [ "$rc" -eq 0 ] || exit 1
		bash -c "$(declare -f N); N /mnt/bin/pi-share --probe; [ \$rc -ne 0 ]" || exit 1
		setsid -w setpriv --reuid 1000 --regid 1000 --init-groups -- sudo -n /mnt/bin/pi-share --probe >/dev/null 2>&1 && exit 1
		[ "$(auth_count)" -eq 1 ] || exit 1
	'
	echo "$output"
	[ "$status" -eq 0 ]
}
