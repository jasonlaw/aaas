#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Agent as a Service"
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
SOURCE_DIR=""
if [[ -n "$SCRIPT_PATH" && "$SCRIPT_PATH" != "bash" && "$SCRIPT_PATH" != "/dev/stdin" ]]; then
  SOURCE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
fi
ROOT_DIR="${AAAS_ROOT:-/opt/aaas}"
PLATFORM_DIR="${ROOT_DIR}/platform"
WATCHDOG_DIR="${PLATFORM_DIR}/watchdog"
# Platform-owned env file consumed by watchdog.sh and the systemd units.
# Deliberately lives outside Hermes's own directory (AAAS_HOME/.hermes):
# install.sh must never write into that directory, since that's where
# `hermes setup` later stores real provider config and secrets.
CONFIG_FILE="${PLATFORM_DIR}/.env"
AAAS_REPO_URL="${AAAS_REPO_URL:-https://github.com/jasonlaw/aaas.git}"
AAAS_REPO_REF="${AAAS_REPO_REF:-master}"
HERMES_OFFICIAL_INSTALL_URL="${HERMES_OFFICIAL_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
LOG_FILE="${WATCHDOG_DIR}/watchdog.log"
ALERT_DIR="${WATCHDOG_DIR}/alerts"

# Dedicated service account that owns all AaaS files and runs all services.
AAAS_USER="aaas"
AAAS_GROUP="aaas"
# Resolved after ensure_aaas_user() runs — always derived from /etc/passwd
# so it is correct whether aaas was just created or already existed.
AAAS_HOME=""
# The user who invoked this script (may equal AAAS_USER).
LOGIN_USER="${SUDO_USER:-${USER:-$(id -un)}}"
# If the installer is already running as aaas (e.g. WSL default user), give
# aaas an interactive shell so the operator can use it directly. Otherwise
# aaas is a background service account and nologin is the safer default.
# NOTE: this only decides the shell used at *creation* time. Whether an
# *existing* account's shell gets touched afterward is handled separately
# in ensure_aaas_user() — see the comment there for why upgrade-only logic
# is required (WSL's pre-created interactive aaas account must never be
# silently downgraded to nologin just because a different user runs this
# installer).
if [[ "$LOGIN_USER" == "$AAAS_USER" ]]; then
  AAAS_SHELL="/bin/bash"
else
  AAAS_SHELL="/usr/sbin/nologin"
fi

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  BOLD="$(tput bold)"
  DIM="$(tput dim)"
  RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"
  MAGENTA="$(tput setaf 5)"
  CYAN="$(tput setaf 6)"
else
  BOLD=""
  DIM=""
  RESET=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  MAGENTA=""
  CYAN=""
fi

# Root-only operations (package installs, systemd unit files, /usr/local/bin
# symlink, useradd/usermod) still go through sudo. Everything that operates
# on files under ROOT_DIR runs as AAAS_USER via run_as_aaas / sudo -u aaas.
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

trap 'fail "Installation stopped near line ${LINENO}."' ERR

# ---------------------------------------------------------------------------
# run_as_aaas — run a command as the aaas user.
#
# If the current user IS aaas (LOGIN_USER == AAAS_USER, or EUID matches),
# the command runs directly — no sudo needed (WSL scenario where aaas is
# the primary login user, or any case where the installer runs as aaas).
# Otherwise it delegates via `sudo -u aaas`.
# ---------------------------------------------------------------------------
run_as_aaas() {
  if [[ "$(id -un)" == "$AAAS_USER" ]]; then
    "$@"
  else
    $SUDO -u "$AAAS_USER" "$@"
  fi
}

banner() {
  printf "\n%s%s\n" "${BOLD}${MAGENTA}" "   ___                ____"
  printf "%s\n" "  / _ |  ___ _ ___ _ / __/"
  printf "%s\n" " / __ | / _  |/ _  | _\\ \\ "
  printf "%s\n" "/_/ |_| \\_,_| \\_,_|/___/ "
  printf "%s%s\n\n" "${CYAN}" "${APP_NAME} installer${RESET}"
}

step() {
  printf "\n%s◆ %s%s\n" "${BLUE}${BOLD}" "$1" "${RESET}"
}

ok() {
  printf "%s✓%s %s\n" "${GREEN}${BOLD}" "${RESET}" "$1"
}

warn() {
  printf "%s!%s %s\n" "${YELLOW}${BOLD}" "${RESET}" "$1" >&2
}

fail() {
  printf "%s✗%s %s\n" "${RED}${BOLD}" "${RESET}" "$1" >&2
  exit 1
}

prompt_read() {
  local prompt="$1"
  local answer_var="$2"

  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" "$answer_var" </dev/tty
  else
    read -r -p "$prompt" "$answer_var"
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer

  if [[ -n "$default" ]]; then
    prompt_read "$(printf "%s?%s %s [%s, Enter to accept]: " "${CYAN}${BOLD}" "${RESET}" "$prompt" "$default")" answer
    printf "%s" "${answer:-$default}"
  else
    prompt_read "$(printf "%s?%s %s: " "${CYAN}${BOLD}" "${RESET}" "$prompt")" answer
    printf "%s" "$answer"
  fi
}

ask_required() {
  local prompt="$1"
  local default="${2:-}"
  local answer

  while true; do
    answer="$(ask "$prompt" "$default")"
    if [[ -n "$answer" ]]; then
      printf "%s" "$answer"
      return
    fi
    warn "$prompt is required."
  done
}

ask_secret_required() {
  local prompt="$1"
  local answer

  while true; do
    answer="$(ask_secret "$prompt")"
    if [[ -n "$answer" ]]; then
      printf "%s" "$answer"
      return
    fi
    warn "$prompt is required."
  done
}

ask_secret() {
  local prompt="$1"
  local answer
  prompt_read "$(printf "%s?%s %s: " "${CYAN}${BOLD}" "${RESET}" "$prompt")" answer
  printf "%s" "$answer"
}

yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local answer hint

  if [[ "$default" =~ ^[Yy] ]]; then
    hint="Y/n, Enter for Y"
  else
    hint="y/N, Enter for N"
  fi

  prompt_read "$(printf "%s?%s %s [%s]: " "${CYAN}${BOLD}" "${RESET}" "$prompt" "$hint")" answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

have() {
  command -v "$1" >/dev/null 2>&1
}

path_add() {
  local dir="$1"

  [[ -d "$dir" ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

refresh_path_from_profile() {
  local profile="$1"
  local profile_path

  [[ -f "$profile" ]] || return 0
  while IFS= read -r profile_path; do
    profile_path="${profile_path/#\~/$HOME}"
    profile_path="${profile_path//\$HOME/$HOME}"
    path_add "$profile_path"
  done < <(grep -Eo "(^|:)(~|\$HOME|/)[^:\"' ]+/bin" "$profile" 2>/dev/null | sed "s/^://" || true)
  return 0
}

refresh_path() {
  local dir binary
  local extra_paths=(
    "$HOME/.opencode/bin"
    "$HOME/.local/share/opencode/bin"
    "$HOME/.local/bin"
    "$HOME/.hermes/bin"
    "${AAAS_HOME:+$AAAS_HOME/.hermes/bin}"
    "$HOME/.npm-global/bin"
    "$HOME/.npm/bin"
    "/usr/local/bin"
    "/opt/homebrew/bin"
  )

  for dir in "${extra_paths[@]}"; do
    path_add "$dir"
  done

  refresh_path_from_profile "$HOME/.profile"
  refresh_path_from_profile "$HOME/.bashrc"
  refresh_path_from_profile "$HOME/.bash_profile"
  refresh_path_from_profile "$HOME/.zshrc"

  if ! command -v opencode >/dev/null 2>&1 && have find; then
    binary="$(find "$HOME/.opencode" "$HOME/.local" "$HOME/.cache" -type f -name opencode -perm /111 2>/dev/null | head -n 1 || true)"
    [[ -z "$binary" ]] || path_add "$(dirname "$binary")"
  fi

  export PATH
}

install_banner() {
  local name="$1"
  printf "\n%s%s%s\n" "${MAGENTA}${BOLD}" "Installing ${name}" "${RESET}"
  printf "%s\n" "------------------------"
}

config_value() {
  local key="$1"

  [[ -f "$CONFIG_FILE" ]] || return 0
  grep -E "^${key}=" "$CONFIG_FILE" | tail -n 1 | cut -d= -f2-
}

yaml_quote() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

npm_global_has() {
  local package="$1"

  have npm || return 1
  npm list -g "$package" --depth=0 >/dev/null 2>&1
}

run() {
  printf "%s→%s %s\n" "${DIM}" "${RESET}" "$*"
  "$@"
}

run_apt() {
  local lock_timeout="${APT_LOCK_TIMEOUT:-300}"
  run $SUDO apt-get -o DPkg::Lock::Timeout="$lock_timeout" "$@"
}

write_alert() {
  local message="$1"
  local alert_path

  alert_path="${ALERT_DIR}/alert-$(date "+%Y%m%d-%H%M%S")-$$"
  run_as_aaas mkdir -p "$alert_path"
  printf "[%s] %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$message" | run_as_aaas tee "${alert_path}/alert.txt" >/dev/null
  warn "$message"
  if have opencode; then
    (cd "$PLATFORM_DIR" && opencode run "AaaS installer alert: $message. Inspect ${alert_path}/alert.txt, repair the issue, rerun install.sh if needed, then remove the folder ${alert_path} after picking up this alert.") >>"$LOG_FILE" 2>&1 || true
  fi
}

process_running() {
  local pattern="$1"

  pgrep -f "$pattern" >/dev/null 2>&1
}

start_background_service() {
  local pattern="$1"
  shift

  if process_running "$pattern"; then
    ok "$pattern is running."
    return 0
  fi

  printf "%s→%s starting %s\n" "${DIM}" "${RESET}" "$pattern"
  # Run the background service as the aaas user.
  nohup run_as_aaas "$@" >>"$LOG_FILE" 2>&1 &
  sleep 3

  process_running "$pattern"
}

# Create dir and ensure it is owned by aaas:aaas with group-write so that
# both the service account and members of the aaas group can write to it.
ensure_owned_dir() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    if ! run_as_aaas mkdir -p "$dir" 2>/dev/null; then
      [[ -n "$SUDO" ]] || fail "Cannot create $dir. Rerun as root or install sudo."
      run $SUDO mkdir -p "$dir"
    fi
  fi

  # Transfer ownership to aaas:aaas and grant group-write so that members of
  # the aaas group (including the login user) can read/write the directory.
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$dir"
  run $SUDO chmod 2775 "$dir"   # setgid bit: new files inherit aaas group

  ok "Directory ready (owned by ${AAAS_USER}:${AAAS_GROUP}): $dir"
}

# ---------------------------------------------------------------------------
# Dedicated service account
# ---------------------------------------------------------------------------

# Create the aaas system group and user if they do not already exist.
# The user gets no login shell and its home directory is ROOT_DIR.
# If the invoking user is different from aaas, they are added to the aaas
# group so they can read/write files under ROOT_DIR.
ensure_aaas_user() {
  step "Ensuring '${AAAS_USER}' service account exists"

  if ! getent group "$AAAS_GROUP" >/dev/null 2>&1; then
    run $SUDO groupadd --system "$AAAS_GROUP"
    ok "Created group ${AAAS_GROUP}."
  else
    ok "Group ${AAAS_GROUP} already exists."
  fi

  if ! id "$AAAS_USER" >/dev/null 2>&1; then
    run $SUDO useradd \
      --system \
      --gid "$AAAS_GROUP" \
      --home-dir "$ROOT_DIR" \
      --no-create-home \
      --shell "$AAAS_SHELL" \
      "$AAAS_USER"
    ok "Created system user ${AAAS_USER} (home: ${ROOT_DIR}, shell: ${AAAS_SHELL})."
  else
    ok "User ${AAAS_USER} already exists."
    # Only ever UPGRADE the shell (nologin -> bash), and only when we are
    # currently running interactively as aaas ourselves. We deliberately
    # never downgrade an existing shell (bash -> nologin): aaas may already
    # be a real interactive account (e.g. WSL's pre-created default user),
    # and a *different* login user rerunning this installer must not be
    # able to silently lock that account down to nologin out from under
    # whoever normally uses it.
    local current_shell
    current_shell="$(getent passwd "$AAAS_USER" | cut -d: -f7)"
    if [[ "$LOGIN_USER" == "$AAAS_USER" && "$current_shell" != "/bin/bash" ]]; then
      run $SUDO usermod --shell "/bin/bash" "$AAAS_USER"
      ok "Updated ${AAAS_USER} shell: ${current_shell} → /bin/bash."
    elif [[ "$current_shell" != "$AAAS_SHELL" ]]; then
      ok "Leaving existing ${AAAS_USER} shell (${current_shell}) unchanged."
    fi
  fi

  # Always derive AAAS_HOME from /etc/passwd — works whether aaas was just
  # created with --home-dir ROOT_DIR, or already existed with a different home
  # (e.g. WSL pre-created aaas with /home/aaas).
  AAAS_HOME="$(getent passwd "$AAAS_USER" | cut -d: -f6)"
  [[ -n "$AAAS_HOME" ]] || fail "Cannot determine home directory for ${AAAS_USER} from /etc/passwd."
  ok "Resolved ${AAAS_USER} home: ${AAAS_HOME}."

  # If the person running install.sh is not aaas, add them to the aaas group
  # so they can read/write files under ROOT_DIR without needing sudo.
  if [[ "$LOGIN_USER" != "$AAAS_USER" ]]; then
    if id -nG "$LOGIN_USER" 2>/dev/null | grep -qw "$AAAS_GROUP"; then
      ok "${LOGIN_USER} is already a member of ${AAAS_GROUP}."
    else
      run $SUDO usermod -aG "$AAAS_GROUP" "$LOGIN_USER"
      ok "Added ${LOGIN_USER} to the ${AAAS_GROUP} group."
      warn "Group membership takes effect in new shells. Run 'newgrp ${AAAS_GROUP}' or log out/in."
    fi
  fi
}


# Ensure /opt/aaas/.bash_profile sources .bashrc so that `bash -li` (login
# shell) reliably loads whatever PATH entries the Hermes installer wrote into
# .bashrc. Without this, bash -li sources /etc/profile and ~/.bash_profile
# only — NOT ~/.bashrc — so the Hermes bin dir is invisible to login shells.
ensure_aaas_profile() {
  local profile="${AAAS_HOME}/.bash_profile"
  # Use a unique marker comment so the idempotency check is unambiguous —
  # grep for the marker, not the actual shell line, to avoid quoting issues.
  local marker="# AaaS: source .bashrc for login shells"

  if [[ -f "$profile" ]] && grep -Fq "$marker" "$profile" 2>/dev/null; then
    ok "${profile} already sources .bashrc."
    return
  fi

  # Append the sourcing block. Using run_as_aaas tee -a avoids quoting
  # issues with heredocs passed through sudo.
  printf '\n%s\n%s\n' "$marker" '[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc"' \
    | run_as_aaas tee -a "$profile" >/dev/null
  ok "Updated ${profile} to source .bashrc for login shells."
}

sync_platform_files() {
  step "Cloning platform presetup"

  local source_platform=""
  local tmp_source=""

  if [[ -n "$SOURCE_DIR" && -d "${SOURCE_DIR}/platform" ]]; then
    source_platform="${SOURCE_DIR}/platform"
  else
    tmp_source="$(mktemp -d)"
    git clone --depth 1 --branch "$AAAS_REPO_REF" "$AAAS_REPO_URL" "$tmp_source/aaas"
    source_platform="${tmp_source}/aaas/platform"
  fi

  [[ -d "$source_platform" ]] || fail "Source platform folder not found: $source_platform"

  if [[ "$(cd "$source_platform" && pwd -P)" == "$(cd "$PLATFORM_DIR" && pwd -P)" ]]; then
    ok "Platform source and target are the same; nothing to clone."
    [[ -z "$tmp_source" ]] || rm -rf "$tmp_source"
    return
  fi

  ensure_owned_dir "$PLATFORM_DIR"

  if have tar; then
    tar \
      -C "$source_platform" -cf - . | run_as_aaas tar -C "$PLATFORM_DIR" -xf -
  else
    run_as_aaas cp -a "$source_platform/." "$PLATFORM_DIR/"
  fi

  # Ensure all synced files are owned by aaas:aaas.
  run $SUDO chown -R "$AAAS_USER:$AAAS_GROUP" "$PLATFORM_DIR"

  [[ -z "$tmp_source" ]] || rm -rf "$tmp_source"
  ok "Platform presetup files are in ${PLATFORM_DIR}."
}

detect_pm() {
  if have apt-get; then
    printf "apt"
  elif have dnf; then
    printf "dnf"
  elif have yum; then
    printf "yum"
  elif have pacman; then
    printf "pacman"
  elif have brew; then
    printf "brew"
  else
    printf "unknown"
  fi
}

install_packages() {
  local pm="$1"
  shift
  local packages=("$@")

  case "$pm" in
    apt)
      run_apt update
      run_apt install -y "${packages[@]}"
      ;;
    dnf)
      run $SUDO dnf install -y "${packages[@]}"
      ;;
    yum)
      run $SUDO yum install -y "${packages[@]}"
      ;;
    pacman)
      run $SUDO pacman -Sy --needed --noconfirm "${packages[@]}"
      ;;
    brew)
      run brew install "${packages[@]}"
      ;;
    *)
      warn "No supported package manager found. Please install: ${packages[*]}"
      return 1
      ;;
  esac
}

ensure_base_tools() {
  step "Preparing the runway"
  local tool missing=()

  for tool in curl git; do
    have "$tool" || missing+=("$tool")
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    install_packages "$(detect_pm)" "${missing[@]}" || true
    for tool in "${missing[@]}"; do
      have "$tool" || fail "$tool is required but is not installed."
    done
  fi

  # Directories are created after ensure_aaas_user, so ownership can be set
  # correctly. Here we just make sure ROOT_DIR exists so useradd --home-dir
  # doesn't complain.
  [[ -d "$ROOT_DIR" ]] || run $SUDO mkdir -p "$ROOT_DIR"
  ok "Base tools are ready."
}

ensure_node() {
  step "Installing Node.js and npm"

  if have node && have npm; then
    ok "Node $(node --version) and npm $(npm --version) are already installed."
    return
  fi

  case "$(detect_pm)" in
    apt)
      run_apt update
      run_apt install -y nodejs npm
      ;;
    dnf|yum|pacman|brew)
      install_packages "$(detect_pm)" nodejs npm || install_packages "$(detect_pm)" node npm || true
      ;;
    *)
      warn "Install Node.js 20+ and npm, then rerun this installer."
      ;;
  esac

  have node && have npm && ok "Node and npm are installed." || warn "Node/npm still need manual installation."
}

ensure_opencode() {
  step "Installing opencode"

  refresh_path
  if have opencode; then
    ok "opencode is already available at $(command -v opencode)."
    return
  fi

  install_banner "opencode"
  if have npm; then
    if npm_global_has opencode-ai; then
      ok "opencode-ai is already installed globally."
    else
      if [[ -n "$SUDO" ]]; then
        run $SUDO npm install -g opencode-ai
      else
        run npm install -g opencode-ai
      fi
    fi
    refresh_path
  else
    warn "npm is not available; trying opencode install script as a fallback."
    local install_url="${OPENCODE_INSTALL_URL:-https://opencode.ai/install}"
    curl -fsSL "$install_url" | bash || warn "opencode install script could not fetch version information."
    refresh_path
  fi

  have opencode && ok "opencode is installed at $(command -v opencode)." || warn "opencode is not on PATH. The watchdog will still write alerts."
}

# PyYAML is required to merge .hermes/config.yaml (staging) into whatever
# config.yaml the Hermes setup wizard produces, without clobbering other
# top-level keys or introducing duplicate YAML keys.
ensure_python_yaml() {
  step "Checking for PyYAML"

  if have python3 && python3 -c "import yaml" >/dev/null 2>&1; then
    ok "python3-yaml is already available."
    return
  fi

  case "$(detect_pm)" in
    apt)
      run_apt update
      run_apt install -y python3 python3-yaml
      ;;
    dnf)
      run $SUDO dnf install -y python3 python3-pyyaml
      ;;
    yum)
      run $SUDO yum install -y python3 python3-pyyaml
      ;;
    pacman)
      run $SUDO pacman -Sy --needed --noconfirm python python-yaml
      ;;
    brew)
      run brew install python pyyaml
      ;;
    *)
      warn "No supported package manager found. Please install PyYAML for python3 manually."
      ;;
  esac

  if have python3 && python3 -c "import yaml" >/dev/null 2>&1; then
    ok "python3-yaml is installed."
  else
    fail "PyYAML is required for Hermes config merging but could not be installed."
  fi
}

ensure_docker() {
  step "Installing Docker Engine"

  if have docker; then
    ok "Docker is already available."
    # Add aaas user to the docker group so it can run containers without sudo.
    if getent group docker >/dev/null 2>&1; then
      if ! id -nG "$AAAS_USER" 2>/dev/null | grep -qw docker; then
        run $SUDO usermod -aG docker "$AAAS_USER"
        ok "Added ${AAAS_USER} to the docker group."
      else
        ok "${AAAS_USER} is already in the docker group."
      fi
    fi
    return
  fi

  case "$(detect_pm)" in
    apt)
      run_apt update
      run_apt install -y ca-certificates curl gnupg
      run $SUDO install -m 0755 -d /etc/apt/keyrings
      if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      else
        ok "Docker apt keyring already exists."
      fi
      run $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
      local docker_source
      docker_source="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable"
      if [[ ! -f /etc/apt/sources.list.d/docker.list ]] || ! grep -Fxq "$docker_source" /etc/apt/sources.list.d/docker.list; then
        printf "%s\n" "$docker_source" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
      else
        ok "Docker apt source already exists."
      fi
      run_apt update
      run_apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    dnf)
      run $SUDO dnf install -y dnf-plugins-core
      run $SUDO dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      run $SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    yum)
      run $SUDO yum install -y yum-utils
      run $SUDO yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      run $SUDO yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    brew)
      run brew install --cask docker || warn "Start Docker Desktop manually after installation."
      ;;
    *)
      warn "Docker could not be installed automatically on this platform."
      ;;
  esac

  if have systemctl && have docker; then
    run $SUDO systemctl enable --now docker || true
  fi

  # Add aaas to docker group after install.
  if getent group docker >/dev/null 2>&1; then
    if ! id -nG "$AAAS_USER" 2>/dev/null | grep -qw docker; then
      run $SUDO usermod -aG docker "$AAAS_USER"
      ok "Added ${AAAS_USER} to the docker group."
    fi
  fi

  have docker && ok "Docker is installed." || warn "Docker still needs manual installation."
}

# Hermes is installed as the aaas user so that:
#   - All files under Hermes's home (AAAS_HOME/.hermes) are owned by aaas
#   - The binary lands in aaas's local path
#   - Anyone wanting to run `hermes` must do so as aaas
install_hermes() {
  step "Installing Hermes"

  local install_url
  install_url="${HERMES_INSTALL_URL:-$HERMES_OFFICIAL_INSTALL_URL}"

  if run_as_aaas bash -li -c "command -v hermes >/dev/null 2>&1" && [[ -d "${AAAS_HOME}/.hermes" ]]; then
    ok "Hermes is already available."
  else
    install_banner "Hermes"
    curl -fsSL "$install_url" | run_as_aaas \
      bash -s -- --skip-setup --non-interactive --skip-browser
    ok "Hermes installer finished."
  fi

  # Safety net: ensure Hermes's home directory and everything in it is
  # owned by aaas.
  run $SUDO chown -R "$AAAS_USER:$AAAS_GROUP" "${AAAS_HOME}/.hermes"
  run $SUDO chmod -R g+rX "${AAAS_HOME}/.hermes"

  run_as_aaas bash -li -c "command -v hermes >/dev/null 2>&1" \
    || fail "hermes is not on PATH for ${AAAS_USER} after install. Fix Hermes install, then rerun install.sh."
  ensure_hermes_wrapper

  # Written to PLATFORM_DIR/.env, not AAAS_HOME/.hermes/.env — install.sh
  # never touches Hermes's own directory, which is where `hermes setup`
  # later stores real provider config and secrets.
  run_as_aaas bash -c "cat >\"$CONFIG_FILE\"" <<EOF
# Generated by install.sh
AAAS_ROOT=${ROOT_DIR}
EOF
  run $SUDO chmod 660 "$CONFIG_FILE"
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  resolve_config_bootstrap_placeholders
  write_hermes_config_yaml

  write_default_hermes_soul_bootstrap
  apply_hermes_soul_bootstrap

  warn "Provider, model, fallback, and Telegram are not configured yet."
  warn "Run: sudo -u ${AAAS_USER} hermes setup"
}

# Install a guard wrapper at /usr/local/bin/hermes that:
#   - Allows the command through when running as aaas
#   - Blocks anyone else with a clear error and usage hint
HERMES_BIN=""
HERMES_REAL_BIN=""
ensure_hermes_wrapper() {
  local real_bin wrapper="/usr/local/bin/hermes"

  # Resolve the actual hermes binary from aaas's perspective.
  real_bin="$(run_as_aaas bash -li -c 'command -v hermes')"
  [[ -n "$real_bin" && "$real_bin" != "$wrapper" ]] \
    || fail "Cannot resolve hermes binary path as ${AAAS_USER}."

  if [[ -n "$SUDO" || "${EUID:-$(id -u)}" -eq 0 ]]; then
    $SUDO tee "$wrapper" >/dev/null <<WRAPPER
#!/usr/bin/env bash
# Managed by AaaS install.sh — do not edit manually.
if [[ "\$(id -un)" != "${AAAS_USER}" ]]; then
  printf "Error: hermes must be run as the '%s' user.\\n" "${AAAS_USER}" >&2
  printf "Use:   sudo -u %s hermes %s\\n" "${AAAS_USER}" '"\$@"' >&2
  exit 1
fi
exec "${real_bin}" "\$@"
WRAPPER
    $SUDO chmod 755 "$wrapper"
    ok "Installed hermes guard wrapper at ${wrapper} (blocks non-${AAAS_USER} users)."
    HERMES_BIN="$wrapper"
    HERMES_REAL_BIN="$real_bin"
  else
    warn "No sudo available to install hermes wrapper into /usr/local/bin; using resolved path directly."
    HERMES_BIN="$real_bin"
    HERMES_REAL_BIN="$real_bin"
  fi
}

# Renames a consumed bootstrap file to a timestamped backup.
backup_bootstrap_file() {
  local file="$1"
  local backup="${file}.applied-$(date +%Y%m%d-%H%M%S)"
  run_as_aaas mv "$file" "$backup"
  ok "Backed up consumed bootstrap file to ${backup}."
}

# Applies PLATFORM_DIR/.hermes/config.yaml onto the config.yaml produced by
# Hermes's own setup wizard, via a real YAML parse/merge (not text-append).
write_hermes_config_yaml() {
  local hermes_config="${AAAS_HOME}/.hermes/config.yaml"
  local bootstrap_file="${PLATFORM_DIR}/.hermes/config.yaml"

  if [[ ! -f "$hermes_config" ]]; then
    warn "config.yaml not found at ${hermes_config}; skipping bootstrap merge."
    return
  fi

  if [[ ! -f "$bootstrap_file" ]]; then
    ok "No .hermes/config.yaml staging file found; leaving config.yaml as generated by Hermes."
    return
  fi

  run_as_aaas env BOOTSTRAP_FILE="$bootstrap_file" python3 - "$hermes_config" <<'PYEOF'
import os, re, sys
import yaml

path = sys.argv[1]
bootstrap_path = os.environ["BOOTSTRAP_FILE"]

with open(path) as f:
    cfg = yaml.safe_load(f) or {}

with open(bootstrap_path) as f:
    bootstrap_text = f.read()

commented_keys = set(re.findall(r'^#[ ]?([A-Za-z0-9_.-]+):', bootstrap_text, re.MULTILINE))

bootstrap = yaml.safe_load(bootstrap_text) or {}

def deep_merge(base, overlay):
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = value
    return base

deep_merge(cfg, bootstrap)

dumped = yaml.dump(cfg, default_flow_style=False, sort_keys=False)

def comment_out_block(text, key):
    out = []
    in_block = False
    for line in text.splitlines(keepends=True):
        if re.match(rf'^{re.escape(key)}:', line):
            in_block = True
            out.append('# ' + line)
            continue
        if in_block:
            if line.strip() == '':
                out.append(line)
                continue
            if line.startswith((' ', '\t')):
                out.append('# ' + line)
                continue
            in_block = False
        out.append(line)
    return ''.join(out)

for key in sorted(commented_keys):
    dumped = comment_out_block(dumped, key)

with open(path, "w") as f:
    f.write(dumped)
PYEOF

  # Re-lock ownership/permissions after Python rewrote the file.
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$hermes_config"
  run $SUDO chmod 660 "$hermes_config"

  backup_bootstrap_file "$bootstrap_file"
  ok "Applied .hermes/config.yaml to config.yaml."
}

# Resolves __PLATFORM_DIR__ and __HERMES_HOME__ placeholders in the
# bootstrap config.yaml before write_hermes_config_yaml applies it.
resolve_config_bootstrap_placeholders() {
  local bootstrap_file="${PLATFORM_DIR}/.hermes/config.yaml"

  [[ -f "$bootstrap_file" ]] || return

  if grep -q '__PLATFORM_DIR__' "$bootstrap_file"; then
    run_as_aaas sed -i "s|__PLATFORM_DIR__|${PLATFORM_DIR}|g" "$bootstrap_file"
    ok "Resolved __PLATFORM_DIR__ in .hermes/config.yaml (staging)."
  fi

  if grep -q '__HERMES_HOME__' "$bootstrap_file"; then
    run_as_aaas sed -i "s|__HERMES_HOME__|${AAAS_HOME}/.hermes|g" "$bootstrap_file"
    ok "Resolved __HERMES_HOME__ in .hermes/config.yaml (staging)."
  fi
}

# Copies PLATFORM_DIR/.hermes/SOUL.md to AAAS_HOME/.hermes/SOUL.md.
apply_hermes_soul_bootstrap() {
  local soul_file="${AAAS_HOME}/.hermes/SOUL.md"
  local bootstrap_file="${PLATFORM_DIR}/.hermes/SOUL.md"

  if [[ ! -f "$bootstrap_file" ]]; then
    ok "No .hermes/SOUL.md staging file found; leaving SOUL.md as Hermes seeds it."
    return
  fi

  run_as_aaas cp "$bootstrap_file" "$soul_file"
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$soul_file"
  run $SUDO chmod 660 "$soul_file"

  backup_bootstrap_file "$bootstrap_file"
  ok "Applied .hermes/SOUL.md to SOUL.md."
}

write_default_hermes_soul_bootstrap() {
  local bootstrap_file="${PLATFORM_DIR}/.hermes/SOUL.md"

  if [[ -f "$bootstrap_file" ]]; then
    ok ".hermes/SOUL.md staging file already present; leaving it as-is."
    return
  fi

  ok "No default .hermes/SOUL.md staging file written; create one at ${bootstrap_file} to preset SOUL.md."
}

# ---------------------------------------------------------------------------
# Install Mnemosyne as Hermes's sole memory provider.
#
# Canonical method per https://github.com/mnemosyne-oss/mnemosyne:
#
#   pip install mnemosyne-hermes        — plugin wrapper + entry points
#                                         (always required for Hermes)
#   + one of:
#   pip install mnemosyne-memory        — core only, ~50 MB RAM
#                                         no local embeddings; point
#                                         MNEMOSYNE_EMBEDDING_API_URL externally
#   pip install mnemosyne-memory[embeddings]  — adds fastembed, ~800 MB RAM
#   pip install mnemosyne-memory[all]   — full local LLM + embeddings, ~1.5 GB
#
#   hermes config set memory.provider mnemosyne
#   hermes memory setup                 — activates the provider
#
# The platform/.hermes/config.yaml bootstrap must set:
#   memory:
#     memory_enabled: false        — disables built-in MEMORY.md injection
#     user_profile_enabled: false  — disables built-in USER.md injection
#     provider: mnemosyne
#
# IMPORTANT: do NOT use `hermes tools disable memory` — that also kills all
# 23 Mnemosyne-registered tools. Use memory_enabled: false in config.yaml.
#
# MNEMOSYNE_HOST_LLM_ENABLED routes consolidation LLM calls through Hermes's
# own authenticated provider — no separate API key needed.
# This env var belongs in ~/.hermes/.env (read by Hermes at startup), NOT
# in the AaaS platform .env (only read by watchdog/opencode).
#
# Data lives at ~/.hermes/mnemosyne/data/ (upstream default).
#
# Install profile is controlled by MNEMOSYNE_INSTALL_PROFILE env var:
#   unset / ""   → mnemosyne-memory (core, default, ~50 MB)
#   "embeddings" → mnemosyne-memory[embeddings] (~800 MB, needs 2 GB free RAM)
#   "all"        → mnemosyne-memory[all] (~1.5 GB, needs 8 GB+ free RAM)
# ---------------------------------------------------------------------------
install_mnemosyne() {
  step "Installing Mnemosyne memory provider"

  local hermes_venv="${AAAS_HOME}/.hermes/hermes-agent/venv"
  local venv_python="${hermes_venv}/bin/python"
  local hermes_env="${AAAS_HOME}/.hermes/.env"
  local profile="${MNEMOSYNE_INSTALL_PROFILE:-}"

  # ------------------------------------------------------------------
  # 1. Verify the Hermes venv exists.
  # ------------------------------------------------------------------
  if [[ ! -x "$venv_python" ]]; then
    fail "Hermes venv not found at ${venv_python}. Confirm with: ls ${hermes_venv}/bin/"
  fi
  ok "Hermes venv found at ${hermes_venv}."

  # ------------------------------------------------------------------
  # 2. Bootstrap pip — Hermes venv is built by uv with --no-pip.
  #    ensurepip is idempotent; --upgrade is a no-op if pip is current.
  # ------------------------------------------------------------------
  run_as_aaas "$venv_python" -m ensurepip --upgrade

  # ------------------------------------------------------------------
  # 3. Install the core library with the chosen profile, plus the
  #    mnemosyne-hermes plugin wrapper (always required for Hermes).
  #
  #    mnemosyne-hermes wraps mnemosyne-memory with the plugin manifest
  #    and entry points that Hermes's plugin system discovers. Both
  #    packages must be present; installing mnemosyne-memory alone is
  #    not sufficient for Hermes to recognise the provider.
  # ------------------------------------------------------------------
  local core_pkg
  if [[ -n "$profile" ]]; then
    core_pkg="mnemosyne-memory[${profile}]"
  else
    core_pkg="mnemosyne-memory"
  fi

  local installed_core_ver installed_hermes_ver
  installed_core_ver="$(run_as_aaas "$venv_python" -m pip show mnemosyne-memory 2>/dev/null | awk '/^Version:/ {print $2}')"
  installed_hermes_ver="$(run_as_aaas "$venv_python" -m pip show mnemosyne-hermes 2>/dev/null | awk '/^Version:/ {print $2}')"

  if [[ -n "$installed_core_ver" && -n "$installed_hermes_ver" ]]; then
    ok "mnemosyne-memory ${installed_core_ver} and mnemosyne-hermes ${installed_hermes_ver} already installed; skipping."
  else
    install_banner "mnemosyne (${core_pkg} + mnemosyne-hermes)"
    run_as_aaas "$venv_python" -m pip install --quiet --upgrade "$core_pkg" mnemosyne-hermes
    ok "Installed ${core_pkg} and mnemosyne-hermes in Hermes venv."
  fi

  # ------------------------------------------------------------------
  # 4. Register mnemosyne as the active memory provider.
  #    `hermes config set` writes memory.provider: mnemosyne into
  #    ~/.hermes/config.yaml without requiring an interactive session.
  # ------------------------------------------------------------------
  run_as_aaas bash -li -c "hermes config set memory.provider mnemosyne"
  ok "memory.provider set to mnemosyne in Hermes config."

  # ------------------------------------------------------------------
  # 5. Activate the provider — idempotent guard first.
  #    `hermes memory setup` is not documented as idempotent: on a
  #    second run it may prompt, error, or attempt to reinitialise an
  #    already-active provider, which could trip set -e.
  #
  #    Guard: skip setup entirely if BOTH conditions are true:
  #      a) the plugin directory already exists (setup ran before), AND
  #      b) config already names mnemosyne as the provider.
  #    If either is missing, run setup. The warn path is a soft
  #    fallback for TTY-only environments; it does not abort the install.
  # ------------------------------------------------------------------
  local plugins_dir="${AAAS_HOME}/.hermes/plugins/mnemosyne"
  local current_provider
  current_provider="$(run_as_aaas bash -li -c \
    "hermes config get memory.provider 2>/dev/null || true")"

  if [[ -d "$plugins_dir" && "$current_provider" == "mnemosyne" ]]; then
    ok "Mnemosyne provider already active (plugin dir exists, provider confirmed); skipping hermes memory setup."
  elif run_as_aaas bash -li -c \
    "hermes memory setup --provider mnemosyne --non-interactive" 2>/dev/null; then
    ok "Mnemosyne provider activated via hermes memory setup."
  else
    warn "hermes memory setup could not run non-interactively (may need a TTY)."
    warn "Run manually after install: sudo -u ${AAAS_USER} hermes memory setup"
    warn "Select 'mnemosyne' from the picker when prompted."
  fi

  # ------------------------------------------------------------------
  # 6. Write MNEMOSYNE_HOST_LLM_ENABLED to ~/.hermes/.env.
  #    This routes Mnemosyne's consolidation and fact-extraction LLM
  #    calls through Hermes's own authenticated provider, so no
  #    separate API key is needed for memory operations.
  #
  #    ~/.hermes/.env is the correct location — Hermes reads it at
  #    startup. The AaaS platform .env (CONFIG_FILE) is only consumed
  #    by the watchdog and opencode, not by Hermes itself.
  # ------------------------------------------------------------------
  if grep -Fq "MNEMOSYNE_HOST_LLM_ENABLED" "$hermes_env" 2>/dev/null; then
    ok "MNEMOSYNE_HOST_LLM_ENABLED already set in ${hermes_env}."
  else
    printf "MNEMOSYNE_HOST_LLM_ENABLED=true\n" | run_as_aaas tee -a "$hermes_env" >/dev/null
    ok "MNEMOSYNE_HOST_LLM_ENABLED=true written to ${hermes_env}."
  fi

  # Re-lock ownership/permissions on .env after writing.
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$hermes_env"
  run $SUDO chmod 660 "$hermes_env"

  ok "Mnemosyne install complete."
  ok "Data will live at ${AAAS_HOME}/.hermes/mnemosyne/data/"
  warn "After gateway restart, verify with:"
  warn "  sudo -u ${AAAS_USER} hermes memory status"
  warn "  sudo -u ${AAAS_USER} hermes tools list | grep mnemosyne"
  warn "  sudo -u ${AAAS_USER} hermes doctor | grep -A5 'Memory Provider'"
}

write_watchdog() {
  step "Creating the watchdog"

  # Watchdog script runs as the aaas user (enforced by the systemd unit).
  # No sudo needed inside: aaas owns every file it touches.
  run_as_aaas bash -c "cat > '${WATCHDOG_DIR}/watchdog.sh'" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PLATFORM_DIR}/.env"
ALERT_DIR="${SCRIPT_DIR}/alerts"
LOG_FILE="${SCRIPT_DIR}/watchdog.log"

source "$CONFIG_FILE"

stamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log() {
  printf "[%s] %s\n" "$(stamp)" "$*" >>"$LOG_FILE"
}

alert() {
  local alert_path

  alert_path="${ALERT_DIR}/alert-$(date "+%Y%m%d-%H%M%S")-$$"
  mkdir -p "$alert_path"
  printf "[%s] %s\n" "$(stamp)" "$*" >"${alert_path}/alert.txt"
  log "$*"
  if command -v opencode >/dev/null 2>&1; then
    (cd "$PLATFORM_DIR" && opencode run "AaaS watchdog alert: $*. Inspect ${alert_path}/alert.txt, repair Hermes or its gateway, then remove the folder ${alert_path} after picking up this alert.") >>"$LOG_FILE" 2>&1 || true
  fi
}

process_running() {
  pgrep -f "$1" >/dev/null 2>&1
}

start_service() {
  local name="$1"
  shift

  if process_running "$name"; then
    log "$name is running."
    return 0
  fi

  log "$name is not running; starting it."
  nohup "$@" >>"$LOG_FILE" 2>&1 &
  sleep 3

  if ! process_running "$name"; then
    alert "Failed to start $name"
    return 1
  fi
}

HERMES_BIN="$(command -v hermes || true)"
if [[ -z "$HERMES_BIN" && -x /usr/local/bin/hermes ]]; then
  HERMES_BIN="/usr/local/bin/hermes"
fi

if [[ -z "$HERMES_BIN" ]]; then
  alert "Hermes executable is not on PATH"
  exit 1
fi

# The watchdog runs as aaas (via systemd User=aaas), so no sudo needed.
if ! "$HERMES_BIN" gateway status --system >/dev/null 2>&1; then
  log "Hermes gateway system service is not healthy; starting it."
  if ! "$HERMES_BIN" gateway start --system >>"$LOG_FILE" 2>&1; then
    alert "Failed to start Hermes gateway system service"
    exit 1
  fi
fi

if ! "$HERMES_BIN" gateway status --system >>"$LOG_FILE" 2>&1; then
  alert "Hermes gateway system service is not running"
  exit 1
fi
EOF

  run $SUDO chmod +x "${WATCHDOG_DIR}/watchdog.sh"
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "${WATCHDOG_DIR}/watchdog.sh"

  # systemd unit: runs as aaas:aaas — no sudo needed inside the script.
  run_as_aaas bash -c "cat > '${WATCHDOG_DIR}/watchdog.service'" <<EOF
[Unit]
Description=AaaS Hermes watchdog
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${AAAS_USER}
Group=${AAAS_GROUP}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${WATCHDOG_DIR}/watchdog.sh
Restart=always
RestartSec=20
WorkingDirectory=${PLATFORM_DIR}

[Install]
WantedBy=multi-user.target
EOF

  ok "Watchdog script written to ${WATCHDOG_DIR}/watchdog.sh."
  ok "Optional systemd unit written to ${WATCHDOG_DIR}/watchdog.service."
}

configure_hermes_gateway_service_env() {
  local unit_name dropin_dir dropin_file

  unit_name="$($SUDO systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /hermes/ && $1 ~ /gateway/ { print $1; exit }')"

  if [[ -z "$unit_name" ]]; then
    warn "Could not find the installed Hermes gateway systemd unit. It may need a manual service override."
    return
  fi

  dropin_dir="/etc/systemd/system/${unit_name}.d"
  dropin_file="${dropin_dir}/aaas.conf"

  run $SUDO mkdir -p "$dropin_dir"
  # Run the gateway as aaas:aaas. With User=aaas set, systemd resolves $HOME
  # from /etc/passwd automatically, so Hermes finds its config at its own
  # default location without any extra environment variables.
  printf "[Service]\nUser=%s\nGroup=%s\nEnvironmentFile=%s\n" \
    "$AAAS_USER" "$AAAS_GROUP" "$CONFIG_FILE" \
    | $SUDO tee "$dropin_file" >/dev/null
  run $SUDO systemctl daemon-reload
  ok "Hermes gateway service ${unit_name} pinned to ${AAAS_USER}:${AAAS_GROUP}."
}

verify_hermes_runtime() {
  step "Verifying Hermes gateway"

  [[ -f "$CONFIG_FILE" ]] || fail "Hermes config is missing: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  run_as_aaas bash -li -c "command -v hermes >/dev/null 2>&1" \
    || fail "hermes is not on PATH for ${AAAS_USER}. Fix Hermes install, then rerun install.sh."
  run_as_aaas bash -li -c "hermes --help 2>/dev/null" | grep -qi gateway \
    || fail "Hermes gateway command is unavailable. Reinstall Hermes Agent, then rerun install.sh."
  ok "Hermes gateway command is available."

  if [[ -f "${AAAS_HOME}/.hermes/config.yaml" ]]; then
    ok "Hermes config.yaml is present at ${AAAS_HOME}/.hermes."
  else
    warn "Hermes config.yaml not found yet at ${AAAS_HOME}/.hermes/config.yaml — expected, since --skip-setup was used."
    warn "It will be created on first run: sudo -u ${AAAS_USER} hermes doctor"
  fi

  if have systemctl; then
    [[ -n "$SUDO" || "${EUID:-$(id -u)}" -eq 0 ]] || fail "Installing the Hermes gateway system service requires root or sudo."
    [[ -n "$HERMES_REAL_BIN" ]] || fail "HERMES_REAL_BIN is not set. ensure_hermes_wrapper must run before verify_hermes_runtime."

    # All gateway operations need root (they control/query systemd) — use the
    # real binary directly, bypassing the wrapper guard (which blocks non-aaas).
    run $SUDO "$HERMES_REAL_BIN" gateway install --system
    configure_hermes_gateway_service_env

    # gateway install may have already started the service; only call start if
    # it is not already running to avoid a non-zero exit on re-run.
    if ! $SUDO "$HERMES_REAL_BIN" gateway status --system >/dev/null 2>&1; then
      run $SUDO "$HERMES_REAL_BIN" gateway start --system
    else
      ok "Hermes gateway is already running."
    fi

    if ! $SUDO "$HERMES_REAL_BIN" gateway status --system >/dev/null 2>&1; then
      write_alert "Hermes gateway system service failed verification"
      fail "Hermes gateway system service is not running. Check: sudo ${HERMES_REAL_BIN} gateway status --system"
    fi
    ok "Hermes gateway system service is running as ${AAAS_USER}."
  else
    if ! start_background_service "hermes.*gateway" hermes gateway; then
      write_alert "Hermes gateway failed to start"
      fail "Hermes gateway is not running. Fix gateway setup, then rerun install.sh."
    fi
    ok "Hermes gateway is running."
  fi
}

install_watchdog_service() {
  step "Enabling watchdog autostart"

  local unit_name="aaas-watchdog.service"
  local unit_source="${WATCHDOG_DIR}/watchdog.service"
  local unit_target="/etc/systemd/system/${unit_name}"

  [[ -f "$unit_source" ]] || fail "Watchdog service file is missing: $unit_source"

  if ! have systemctl; then
    warn "systemd is not available; watchdog autostart was not installed."
    return
  fi

  [[ -n "$SUDO" || "${EUID:-$(id -u)}" -eq 0 ]] || fail "Installing the watchdog service requires root or sudo."

  run $SUDO install -m 0644 "$unit_source" "$unit_target"
  run $SUDO systemctl daemon-reload
  run $SUDO systemctl enable "$unit_name"

  ok "Watchdog service enabled: ${unit_name} (runs as ${AAAS_USER}). Not started — start it manually when ready:"
  ok "  sudo systemctl start ${unit_name}"
}

summary() {
  printf "\n%s%sInstallation complete.%s\n" "${GREEN}${BOLD}" "✨ " "${RESET}"
  printf "%sService account:%s %s:%s (home: %s)\n" "${BOLD}" "${RESET}" "$AAAS_USER" "$AAAS_GROUP" "$AAAS_HOME"
  printf "%sHermes home:%s    %s\n"        "${BOLD}" "${RESET}" "${AAAS_HOME}/.hermes"
  printf "%sMemory:%s         Mnemosyne → %s/.hermes/mnemosyne/data/mnemosyne.db\n" "${BOLD}" "${RESET}" "${AAAS_HOME}"
  printf "%sConfig:%s         %s\n"        "${BOLD}" "${RESET}" "$CONFIG_FILE"
  printf "%sWatchdog:%s       %s\n"        "${BOLD}" "${RESET}" "${WATCHDOG_DIR}/watchdog.sh"
  if [[ "$LOGIN_USER" != "$AAAS_USER" ]]; then
    printf "%sNote:%s           %s is now a member of the '%s' group.\n" \
      "${BOLD}" "${RESET}" "$LOGIN_USER" "$AAAS_GROUP"
    printf "                 Run ${BOLD}newgrp %s${RESET} or open a new shell to activate it.\n" "$AAAS_GROUP"
    printf "                 To run hermes manually: ${BOLD}sudo -u %s hermes ...${RESET}\n" \
      "$AAAS_USER"
  fi
  if have systemctl && systemctl is-active --quiet aaas-watchdog.service 2>/dev/null; then
    printf "%sService:%s        %s\n" "${BOLD}" "${RESET}" "aaas-watchdog.service active"
  elif have systemctl && systemctl is-enabled --quiet aaas-watchdog.service 2>/dev/null; then
    printf "%sService:%s        %s\n" "${BOLD}" "${RESET}" "aaas-watchdog.service enabled, not started (sudo systemctl start aaas-watchdog.service)"
  fi
  printf "\n%sNext steps:%s\n" "${BOLD}" "${RESET}"
  printf "  1. Complete provider and model configuration:\n"
  printf "       ${BOLD}sudo -u %s hermes setup${RESET}\n" "$AAAS_USER"
  printf "     Follow the interactive wizard to set your API keys and preferred model.\n"
  printf "     Mnemosyne will route its consolidation calls through that same provider.\n"
  printf "\n"
  printf "  2. Verify Mnemosyne is active:\n"
  printf "       ${BOLD}sudo -u %s hermes memory status${RESET}\n" "$AAAS_USER"
  printf "       ${BOLD}sudo -u %s hermes tools list | grep mnemosyne${RESET}\n" "$AAAS_USER"
  printf "       ${BOLD}sudo -u %s hermes doctor | grep -A5 'Memory Provider'${RESET}\n" "$AAAS_USER"
  printf "\n"
  printf "  3. (Optional) Add a fallback provider for reliability:\n"
  printf "       ${BOLD}sudo -u %s hermes fallback add${RESET}\n" "$AAAS_USER"
  printf "\n"
  printf "  4. (Optional) Configure messaging platform integrations (Telegram, etc.):\n"
  printf "       ${BOLD}sudo -u %s hermes gateway setup${RESET}\n" "$AAAS_USER"
  printf "\n"
  printf "  5. After any configuration change, restart the gateway to apply it:\n"
  printf "       ${BOLD}sudo systemctl restart hermes-gateway${RESET}\n"
  printf "\n"
  printf "  6. (Optional) Use local embeddings for better memory recall:\n"
  printf "       Set MNEMOSYNE_INSTALL_PROFILE=embeddings and rerun install.sh\n"
  printf "       Requires ~800 MB RAM. For full local LLM use 'all' (~1.5 GB, 8 GB+ RAM).\n"
  printf "\n"
  printf "%sHermes gateway note:%s\n" "${BOLD}" "${RESET}"
  printf "  The gateway is installed as a systemd system service, which means it\n"
  printf "  starts automatically at boot and runs independently of any user session.\n"
  printf "  This is intentional for a server deployment — ignore any Hermes prompt\n"
  printf "  suggesting a switch to a per-user service.\n"
}

main() {
  banner
  ensure_base_tools
  ensure_aaas_user          # must come before ensure_owned_dir calls
  ensure_owned_dir "$ROOT_DIR"
  ensure_owned_dir "$PLATFORM_DIR"
  ensure_owned_dir "${AAAS_HOME}/.hermes"
  ensure_owned_dir "${AAAS_HOME}/.hermes/skills"
  ensure_owned_dir "$WATCHDOG_DIR"
  ensure_aaas_profile         # must run before install_hermes
  sync_platform_files
  ensure_node
  ensure_opencode
  ensure_python_yaml
  ensure_docker
  install_hermes
  install_mnemosyne
  write_watchdog
  verify_hermes_runtime
  install_watchdog_service
  summary
}

main "$@"