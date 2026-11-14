# pi-read

A [pi](https://github.com/earendil-works/pi) extension that lets the agent read specific root-only files for a limited time, without running it as root.

## Why

Coding agents sometimes need to read files that only root can read: system configuration, logs, service files. The usual options are poor:

- paste the files in by hand, which is tedious;
- run the agent as root, which gives it far too much;
- give the agent a sudo tool, which lets it run any command as root once you approve it;
- loosen file permissions, which affects every program you run and is easy to forget to undo.

pi-read sits in between. The agent asks for the files it needs; you see the request and approve it with your sudo password. The agent gets read-only copies, and they disappear on their own.

## How it works

1. **The agent asks.** It calls the `request_root_read` tool with the files it wants, how long it needs them, and why.
2. **You approve.** pi shows you the request (files, duration, reason), then sudo asks for your password (see [Password prompt](#password-prompt)). Typing it approves the request; cancelling refuses it.
3. **The files are copied and filtered.** A small root-owned script, `pi-share`, copies the files into `/run/pi-share/`, which lives in RAM, and runs [gitleaks](https://github.com/gitleaks/gitleaks) over the copies before anyone can read them: every line gitleaks flags is replaced with `[REDACTED]`, so its secrets never reach the agent (see [Filtering](#filtering)). Only your user can read the copies. No real file is changed.
4. **The agent reads the copies.** The tool tells the agent where each copy is, and it reads them with its normal tools.
5. **The copies are deleted** when the time is up, or earlier if pi exits first. Both are enforced by a root systemd service that `pi-share` starts for each share, so they work even if pi crashes, and need no second password. `pi-share` asks that service when it is due and reports the real deadline, which is a little earlier than "now + duration", since the copying takes time. A reboot clears the copies too, because `/run` is emptied on every boot.

If the agent needs more files later, it asks again, and you approve again.

The copies are snapshots, not the live files. For a fresh copy, the agent asks again.

### Filtering

The copies are not raw snapshots: `pi-share` runs gitleaks over them and replaces every line gitleaks
flags with `[REDACTED]` before the agent can read them. If gitleaks is missing, cannot be trusted, or
fails, nothing is shared and the agent is told why.

- gitleaks must be root-owned and not writable by group or other, and `pi-share` looks for it on its
own `PATH` (`/usr/local/bin`, then the system directories), never yours.
- The scan runs over the copies under a number, not under their real path: gitleaks' default
  configuration skips paths such as `node_modules/` or `package-lock.json`, and a copy keeping its
  path would never be scanned.
- gitleaks cannot rewrite files, so `pi-share` does the redaction from its report. Only lines gitleaks
  reports are touched, and the file keeps its line count; the rest of a flagged line goes with the
  secret, so a structured file (JSON, YAML) can break where it was redacted.
- Nothing you control can steer the scan: `GITLEAKS_CONFIG`, a `gitleaks.toml` and a `.gitleaksignore`
  are ignored, and a `gitleaks:allow` comment inside a file does not opt that line out.

Detection is best effort. A secret no rule matches, one inside an archive, and one in a file gitleaks
could not read all reach the copy: see [What it protects against](#what-it-protects-against-and-what-it-doesnt).

### Directory listings

The agent can also ask for listings of root-only directories, with the `request_root_list` tool:
one level deep (the default) or recursively, up to 10 levels. You approve them the same way, and
the listings are files in the share, filtered through gitleaks and deleted with it. `pi-share`
checks each directory as it checks a file: written out in full (no links), not on the never-share
list, and not writable by you. A never-share directory mounted somewhere else is refused too.

A listing is `ls -l` style: mode, links, owner, group, size, modification time and the path
relative to the listed directory (`.` for itself), sorted by path, after a `#` header line.

- **Never-shared entries are left out.** An entry on the never-share list, a hard link to a
  never-share file, or a never-share directory mounted inside the listed one is left out, along
  with everything below it. A `#` line at the end says how many entries were left out, never which.
- **Links are never followed.** A link is shown as `name -> target`, and its target directory is
  not entered. A link whose target is never shared (as written, or after following the links on
  the way) shows `name -> [never shared]` instead, so a link cannot leak a never-share name.
- **Names cannot fake lines.** A name with a control character (a newline, an escape) is written
  quoted, as `$'...'`.
- **Large trees are cut short.** A listing stops after 5000 entries per directory, or after 30
  seconds, and says so in a `#` line at the end. Entries that root could not read are mentioned
  there too.

### Password prompt

Your password always goes to sudo itself, never to the agent or the conversation. pi-read uses the first of these that works:

1. **In pi.** In an interactive pi session (a terminal, tmux, SSH), pi steps aside and sudo asks on pi's own terminal, exactly as in a normal shell. pi comes back when sudo is done.
2. **A tmux popup.** When pi has no terminal to give up (for example a subagent) but runs inside tmux, sudo asks in a tmux popup.
3. **A graphical askpass.** Otherwise, in a graphical session, sudo asks through an askpass program such as `ksshaskpass`.
4. **Otherwise the request fails**, and the agent is told that no password prompt was available.

Subagents can request files too, through the tmux popup or the askpass. It works, but it is meant for exceptions: prefer letting the main agent ask.

sudo asks every time: pi-read sets `timestamp_timeout=0` for `pi-share`, so no cached sudo session is left for other programs to reuse.

### Limits

| Setting | Value |
| --- | --- |
| Longest share | 60 minutes (`1h`). Built into `pi-share`; nothing the agent asks for can raise it |
| Default share | 15 minutes (`15m`) |
| Size per share | 50 MB, since the copies use RAM |
| Listing depth | 10 levels (default 1) |
| Listing size | 5000 entries per directory, 30 seconds per directory |
| Reason | 200 characters, on one line, so it cannot push the file list off the approval screen |

Durations are written the way `sleep` takes them: `90` or `90s` for seconds, `15m` for minutes, `1h` for hours.

### Files that are never shared

Some files are effectively passwords. `pi-share` refuses them even if you approve them. By default these are:

- password hashes: `/etc/shadow`, `/etc/gshadow`, `/etc/security/opasswd` and their backups
- SSH host private keys: `/etc/ssh/ssh_host_*_key`
- TLS private keys: `/etc/ssl/private`, `/etc/letsencrypt/archive`, `/etc/letsencrypt/live`
- other service secrets: `/etc/krb5.keytab`, `/etc/ipsec.secrets`, `/etc/ppp/*-secrets`
- root's home folder: `/root`
- stored credentials and disk keys: `/etc/credstore`, `/etc/credstore.encrypted`, `/etc/cryptsetup-keys.d`, `/var/lib/systemd/credential.secret`, `/run/credentials`
- network secrets: `/etc/wireguard`, `/etc/NetworkManager/system-connections`, `/run/NetworkManager/system-connections`, `/etc/wpa_supplicant`, `/var/lib/iwd`, `/var/lib/bluetooth`
- the package signing keyring: `/etc/pacman.d/gnupg`
- directory service and virtualisation state: `/var/lib/samba/private`, `/var/lib/sss`, `/etc/libvirt/secrets`
- memory contents: `/var/lib/systemd/coredump` and `/swapfile`
- `/var/lib/docker`

The list is a root-owned file, `/usr/local/etc/pi-read/never-share.list`, and you change it by editing that file as root:

```sh
sudoedit /usr/local/etc/pi-read/never-share.list
```

Changes apply from the next request; there is nothing to re-run. Each line is one absolute path, and it refuses that path and everything below it. `*`, `?` and `[...]` work as in the shell, except that `*` also crosses `/`. Blank lines and lines starting with `#` are ignored. `install.sh` creates the file from the shipped defaults in [`never-share.defaults`](never-share.defaults) when none is installed. Don't edit `never-share.defaults`: nothing reads it after that. To compare your list with the defaults, or go back to them:

```sh
sudo diff -u never-share.defaults /usr/local/etc/pi-read/never-share.list
./install.sh --reset-never-share
```

`pi-share` refuses every request when the list is missing, has no entries, has an entry that is not an absolute path or holds a control character, is a link, is not owned by root, or is writable by you (directly or through a folder above it).

Whatever the list says, `pi-share` also refuses `/proc`, `/sys` and `/dev`, swap devices, anywhere your own user can write (such as `/home` and `/tmp`), and links that lead to any of the above.

Links are refused altogether, as is any path that is not written out in full (`/etc/../etc/fstab`): you approve the path you are shown, so it has to be the file that gets copied. `pi-share` names the real path in its refusal, and the agent can ask for that instead.

Paths with control characters (a tab, a newline) are refused too: `pi-share` prints one file per line as `requested<TAB>copy`, so it could not pass such a path on.

## Installation

```sh
git clone https://github.com/Dr-Dd/pi-read.git
cd pi-read
./install.sh
```

`install.sh` installs everything: the pi extension (through `pi install`) and, after asking for your sudo password, `pi-share`, its sudoers rule and the [never-share list](#files-that-are-never-shared). Read it before you run it: it changes system files. It installs the never-share list only when none is installed yet; your edits are never overwritten (it tells you when your list differs from the shipped defaults). `./install.sh --uninstall` removes everything again except your never-share list; `./install.sh --uninstall --purge` removes that too.

After updating pi-read (a `git pull`), run `./install.sh` again. pi uses the extension straight from this folder, but `pi-share` is a root-owned copy, so it stays at the old version until then. The extension notices the difference and refuses requests, telling the agent to ask you for this.

Requirements: Linux with systemd, sudo, [gitleaks](https://github.com/gitleaks/gitleaks) 8.19 or newer,
and pi. gitleaks has to be root-owned and not writable by your user (a distribution package is fine);
`install.sh` refuses to install without it, and `pi-share` refuses one it cannot trust. Optional: tmux
3.2 or newer for popups, an askpass program for graphical prompts.

## Development

Requirements: Node.js 22.19 or newer, plus `shellcheck` and `shfmt` from your system's package manager. Everything else is pinned in `package-lock.json`:

```sh
npm ci
./check.sh   # typecheck, Biome, shellcheck, shfmt, node:test and bats tests
```

## What it protects against, and what it doesn't

**It does stop:**

- the agent getting anything but read-only copies of the files you approved;
- the agent reading a secret gitleaks recognises: the line it is on is replaced with `[REDACTED]`;
- the agent reading the files on the never-share list, even if you approve them;
- other users on the machine reading the copies;
- shares lasting longer than you allowed, or than the hard limit;
- tricks such as a link in your home folder with a harmless name pointing at another file, or a program planted on your `PATH` to run as root.

**It does not stop:**

- **Other programs running as you.** While a share lasts, any program you run can read the copies, not only pi. The roadmap below fixes this.
- **A tampered pi.** pi and its extensions live in your home folder, so a program running as you could modify them. A tampered pi could show you one request and send another, or capture your password while sudo is asking on its terminal. Your sudo password unlocks everything, not only `pi-share`.
- **The agent copying what it reads** somewhere else, for example into your home folder.
- **Your model provider seeing the files.** Anything the agent reads goes into the conversation. This is why the never-share list exists. Only approve what you would be happy to send.
- **Secrets gitleaks does not recognise.** The filter is only as good as gitleaks' rules. A secret no
  rule matches, one inside an archive, or one in a file gitleaks skipped (it warns instead of failing
  when it cannot read a file) still reaches the copy, and a redacted line keeps no other context.
- **Secrets missing from the list.** The list blocks known secrets; you still approve every file.

## Roadmap

### Only pi can read the shares

Today any program running as you can read a share while it lasts. The plan to limit shares to pi:

1. Create a group called `pi-read`. Your user is *not* a member, so your normal programs don't have it.
2. Start pi with that group added to its process only: `sudo -g pi-read pi`, behind a shell function so you can still type `pi`. The programs pi starts inherit the group. Starting pi asks for your password once.
3. Make the copies readable by the `pi-read` group instead of your user.

The kernel then enforces that only that pi session can read shares. Two limits remain:

- **pi can be tampered with.** pi and its extensions live in your home folder, so a program running as you could modify them and gain the group the next time you start pi. Running pi as a separate user, with its files owned by root, would close this.
- **No password-free launch.** Letting pi start with the group without a password would let any program running as you do the same, which defeats the purpose.

## License

[WTFPL](LICENSE): do what you want with it.
