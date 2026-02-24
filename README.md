# podman-wsl-setup

One-shot script to configure **rootless Podman** in an existing **WSL2 Ubuntu** instance.

Handles package installation, subordinate UID/GID mapping, rootless verification, and an optional Docker-compatible socket, so tools expecting `DOCKER_HOST` just work.

## Prerequisites

| Requirement | Notes |
|---|---|
| **WSL2** with an Ubuntu distro | 23.04+ recommended (for `passt` networking). 22.04 works but falls back to `slirp4netns`. |
| **systemd enabled in WSL** | Required for the optional podman.socket (step 6). See setup below. |
| **Run as your normal user** | The script uses `sudo` only where needed. Do **not** run the script itself with `sudo`. |

### Enable systemd in WSL (one-time, manual)

```bash
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
```

Then from **Windows PowerShell**:

```powershell
wsl --shutdown
```

Reopen WSL Ubuntu and proceed.

## Usage

```bash
git clone https://github.com/<you>/podman-wsl-setup.git
cd podman-wsl-setup
chmod +x setup-rootless-podman.sh
./setup-rootless-podman.sh
```

### Flags

| Flag | Effect |
|---|---|
| `--skip-socket` | Skip step 6 (podman.socket + `DOCKER_HOST`) |
| `--non-interactive` | No prompts; enables the socket by default unless `--skip-socket` is also passed |
| `-h` / `--help` | Print the script header docs and exit |

## What the script does

1. **Environment checks** — detects WSL, systemd state, cgroup version (advisory only, never blocks).
2. **Installs packages** — `podman`, `uidmap`, `dbus-user-session`, `fuse-overlayfs`, `slirp4netns`, and `passt` (if available).
3. **Configures `/etc/subuid` & `/etc/subgid`** — adds a 65536-UID range for the current user if missing.
4. **Runs `podman system migrate`** — only if mappings were just added, to fix storage config.
5. **Verifies rootless Podman** — checks `rootless=true` and runs `quay.io/podman/hello`.
6. **Optional: enables `podman.socket`** — starts the rootless systemd socket and appends `DOCKER_HOST` to `~/.bashrc` for Docker-tool compatibility.

## Tested on

- Ubuntu 24.04 LTS under WSL2 (Windows 11)
- Ubuntu 23.04 under WSL2

Older Ubuntu releases (22.04) should work for steps 1–5 but will lack `passt`; the script detects this and falls back gracefully.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `podman.socket` fails to enable | Enable systemd in `/etc/wsl.conf` and `wsl --shutdown` |
| `rootless=false` reported | Ensure you're not running with `sudo`; check `/etc/subuid` and `/etc/subgid` |
| Container test fails | Check networking — ensure `slirp4netns` or `passt` is installed |
| `cgroup v1 detected` warning | Update your WSL kernel: `wsl --update` from PowerShell |
| Permission errors on `/run/user/<uid>` | Ensure `dbus-user-session` is installed and you've logged in (not just `su`'d) |

## License

[MIT](LICENSE)
