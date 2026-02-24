#!/usr/bin/env bash
# setup-rootless-podman.sh
#
# Purpose:
#   Configure rootless Podman in an existing WSL2 Ubuntu instance.
#
# What this script does:
#   1) Checks environment (WSL, systemd, cgroups)
#   2) Installs Podman + rootless dependencies
#   3) Ensures /etc/subuid and /etc/subgid mappings exist for the current user
#   4) Runs `podman system migrate` if mappings were changed
#   5) Verifies rootless Podman with a container test
#   6) Optionally enables the rootless Docker-compatible Podman socket and
#      appends DOCKER_HOST to ~/.bashrc
#
# IMPORTANT WSL NOTE:
#   Rootless Podman requires systemd in WSL. Recent Windows 11 builds enable
#   it by default for new Ubuntu instances. Verify with:
#     systemctl is-system-running
#
#   If it prints "running" or "degraded", you're set. Otherwise, enable it:
#     sudo tee /etc/wsl.conf >/dev/null <<'WSLCONF'
#     [boot]
#     systemd=true
#     WSLCONF
#
#   Then from Windows PowerShell:
#     wsl --shutdown
#
#   Reopen Ubuntu and run this script.
#
# Usage:
#   chmod +x ./setup-rootless-podman.sh
#   ./setup-rootless-podman.sh
#
# Optional flags:
#   --skip-socket     Skip step 6 (podman.socket + DOCKER_HOST)
#   --non-interactive Do not prompt (enable socket by default unless --skip-socket)
#
# Notes:
#   - Run as your normal WSL user (NOT with sudo).
#   - The script will use sudo only for package install and user mapping config.
#   - Tested on Ubuntu 23.04+ under WSL2. Older releases may lack the 'passt'
#     package (see --help output / README).
# --- END HEADER ---

set -euo pipefail

SKIP_SOCKET=0
NON_INTERACTIVE=0

for arg in "$@"; do
  case "$arg" in
    --skip-socket) SKIP_SOCKET=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    -h|--help)
      # Print only the header comment block (lines between shebang and "END HEADER" sentinel)
      sed -n '2,/^# --- END HEADER ---/{/^# --- END HEADER ---/d; s/^# \{0,1\}//p}' "$0"
      exit 0
      ;;
    --)
      break
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Run with --help for usage information." >&2
      exit 1
      ;;
  esac
done

# --- Logging helpers ---
log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# --- Step 1: Basic checks ---
if [[ "$(id -u)" -eq 0 ]]; then
  die "Do not run this script as root. Run it as your normal WSL user."
fi

require_cmd sudo
require_cmd apt-get
require_cmd grep
require_cmd id

USER_NAME="${USER:-$(id -un)}"
USER_UID="$(id -u)"

log "Running as user: $USER_NAME (uid=$USER_UID)"

# --- WSL detection (informational) ---
if grep -qi microsoft /proc/version 2>/dev/null; then
  log "WSL environment detected"
else
  warn "This does not look like WSL. Script is intended for WSL2 Ubuntu."
fi

# --- systemd check (informational) ---
if command -v systemctl >/dev/null 2>&1; then
  sd_state="$(systemctl is-system-running 2>/dev/null || true)"
  case "$sd_state" in
    running|degraded)
      log "systemd is $sd_state"
      ;;
    *)
      warn "systemd may not be running (state: ${sd_state:-unknown}). In WSL, enable it in /etc/wsl.conf and restart WSL."
      ;;
  esac
else
  warn "systemctl not found. systemd likely not active in this distro."
fi

# --- cgroup version check (informational) ---
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  log "cgroup v2 detected"
else
  warn "cgroup v1 detected. Rootless Podman works best with cgroup v2."
fi

# --- Step 2: Install Podman + dependencies ---
log "Installing Podman and rootless dependencies"

# Build package list — passt is only available on Ubuntu 23.04+
PACKAGES=(podman uidmap dbus-user-session fuse-overlayfs slirp4netns)
if apt-cache show passt &>/dev/null; then
  PACKAGES+=(passt)
  log "passt package found — will install (modern rootless networking)"
else
  warn "passt package not available (Ubuntu < 23.04?). slirp4netns will be used for rootless networking instead."
fi

sudo apt-get update
sudo apt-get install -y "${PACKAGES[@]}"

# --- Step 3: Configure subordinate UID/GID ranges ---
log "Checking /etc/subuid and /etc/subgid entries for $USER_NAME"

SUBUID_EXISTS=0
SUBGID_EXISTS=0
MAPPINGS_CHANGED=0

grep -q "^${USER_NAME}:" /etc/subuid 2>/dev/null && SUBUID_EXISTS=1
grep -q "^${USER_NAME}:" /etc/subgid 2>/dev/null && SUBGID_EXISTS=1

if [[ $SUBUID_EXISTS -eq 1 && $SUBGID_EXISTS -eq 1 ]]; then
  log "subuid/subgid mappings already exist"
else
  log "Adding missing subuid/subgid mappings (100000-165535) for $USER_NAME"
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER_NAME"
  MAPPINGS_CHANGED=1
fi

log "Current mapping entries:"
grep "^${USER_NAME}:" /etc/subuid /etc/subgid || true

# --- Step 4: Migrate if mappings changed ---
if [[ $MAPPINGS_CHANGED -eq 1 ]]; then
  log "Stopping any existing containers before migration"
  podman stop --all 2>/dev/null || true
  log "Running podman system migrate (safe after subuid/subgid changes)"
  podman system migrate || warn "podman system migrate returned non-zero (may succeed after relogin)"
fi

# --- Step 5: Verify rootless Podman ---
log "Verifying rootless Podman setup"
podman info >/dev/null
ROOTLESS="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo 'unknown')"

if [[ "$ROOTLESS" != "true" ]]; then
  warn "Podman is installed but did not report rootless=true (got: $ROOTLESS)"
  warn "Check systemd (WSL), subuid/subgid entries, and ensure you're not using sudo."
else
  log "Podman reports rootless=true"
fi

log "Running a quick container test (quay.io/podman/hello)"
podman run --rm quay.io/podman/hello || warn "Container test failed. Podman is installed, but networking/storage may need attention."

# --- Step 6: Optional Docker-compatible socket (rootless) ---
ENABLE_SOCKET=1
if [[ $SKIP_SOCKET -eq 1 ]]; then
  ENABLE_SOCKET=0
elif [[ $NON_INTERACTIVE -eq 0 ]]; then
  printf '\nEnable rootless podman.socket and add DOCKER_HOST to ~/.bashrc? [Y/n] '
  read -r reply
  case "${reply:-Y}" in
    n|N|no|NO) ENABLE_SOCKET=0 ;;
    *) ENABLE_SOCKET=1 ;;
  esac
fi

if [[ $ENABLE_SOCKET -eq 1 ]]; then
  log "Enabling rootless podman.socket (Docker-compatible socket)"
  if systemctl --user enable --now podman.socket; then
    systemctl --user status podman.socket --no-pager || true
  else
    warn "Failed to enable podman.socket (likely systemd/user service issue in WSL)"
  fi

  # shellcheck disable=SC2016 # Single quotes intentional: $(id -u) must expand at shell startup, not now
  DOCKER_HOST_LINE='export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock'

  if grep -Fq "$DOCKER_HOST_LINE" "$HOME/.bashrc" 2>/dev/null; then
    log "DOCKER_HOST already present in ~/.bashrc"
  else
    log "Adding DOCKER_HOST to ~/.bashrc"
    printf '\n# Podman rootless socket (Docker-compatible)\n%s\n' "$DOCKER_HOST_LINE" >> "$HOME/.bashrc"
  fi

  export DOCKER_HOST="unix:///run/user/${USER_UID}/podman/podman.sock"
  log "DOCKER_HOST for current session: $DOCKER_HOST"
else
  log "Skipping step 6 (podman.socket + DOCKER_HOST)"
fi

# --- Summary ---
cat <<EOF

Done.

Quick checks:
  podman info --format '{{.Host.Security.Rootless}}'
  podman run --rm quay.io/podman/hello

If you enabled step 6:
  source ~/.bashrc
  echo \$DOCKER_HOST
  systemctl --user status podman.socket

If step 6 failed in WSL:
  - Make sure /etc/wsl.conf contains:
      [boot]
      systemd=true
  - Then run from Windows PowerShell:
      wsl --shutdown
  - Reopen Ubuntu and rerun this script (or just rerun step 6 commands)

EOF
