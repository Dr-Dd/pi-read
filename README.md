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
3. **The files are copied.** A small root-owned script, `pi-share`, copies the files into `/run/pi-share/`, which lives in RAM. Only your user can read the copies. No real file is changed.
4. **The agent reads the copies.** The tool tells the agent where each copy is, and it reads them with its normal tools.
5. **The copies are deleted** when the time is up, or earlier if pi exits first. Both are enforced by a root systemd service that `pi-share` starts for each share, so they work even if pi crashes, and need no second password. A reboot clears the copies too, because `/run` is emptied on every boot.

If the agent needs more files later, it asks again, and you approve again.

The copies are snapshots, not the live files. For a fresh copy, the agent asks again.

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

Durations are written the way `sleep` takes them: `90` or `90s` for seconds, `15m` for minutes, `1h` for hours.

### Files that are never shared

Some files are effectively passwords. `pi-share` refuses them even if you approve them:

- password hashes: `/etc/shadow`, `/etc/gshadow` and their backups
- SSH host private keys: `/etc/ssh/ssh_host_*_key`
- root's home folder: `/root`
- stored credentials and disk keys: `/etc/credstore`, `/etc/credstore.encrypted`, `/etc/cryptsetup-keys.d`, `/var/lib/systemd/credential.secret`
- network secrets: `/etc/wireguard`, `/etc/NetworkManager/system-connections`, `/var/lib/iwd`, `/var/lib/bluetooth`
- memory contents: `/var/lib/systemd/coredump`, `/swapfile` and swap devices
- `/var/lib/docker`

It also refuses `/proc`, `/sys` and `/dev`, anywhere your own user can write (such as `/home` and `/tmp`), and links that lead to any of the above.

## Installation

```sh
git clone https://github.com/Dr-Dd/pi-read.git
cd pi-read
./install.sh
```

`install.sh` installs everything: the pi extension (through `pi install`) and, after asking for your sudo password, `pi-share` and its sudoers rule. Read it before you run it: it changes system files. `./install.sh --uninstall` removes everything again.

Requirements: Linux with systemd, sudo and pi. Optional: tmux for popups, an askpass program for graphical prompts.

## Development

Requirements: Node.js 22.19 or newer, plus `shellcheck` and `shfmt` from your system's package manager. Everything else is pinned in `package-lock.json`:

```sh
npm ci
./check.sh   # typecheck, Biome, shellcheck, shfmt, node:test and bats tests
```

## What it protects against, and what it doesn't

**It does stop:**

- the agent getting anything but read-only copies of the files you approved;
- the agent reading the files on the never-share list, even if you approve them;
- other users on the machine reading the copies;
- shares lasting longer than you allowed, or than the hard limit;
- tricks such as a link in your home folder pointing at `/etc/shadow`.

**It does not stop:**

- **Other programs running as you.** While a share lasts, any program you run can read the copies, not only pi. The roadmap below fixes this.
- **A tampered pi.** pi and its extensions live in your home folder, so a program running as you could modify them. A tampered pi could show you one request and send another, or capture your password while sudo is asking on its terminal. Your sudo password unlocks everything, not only `pi-share`.
- **The agent copying what it reads** somewhere else, for example into your home folder.
- **Your model provider seeing the files.** Anything the agent reads goes into the conversation. This is why the never-share list exists. Only approve what you would be happy to send.
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
