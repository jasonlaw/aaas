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

# Platform-owned env file (AAAS_ROOT, HERMES_REAL_BIN). Consumed by
# install.sh itself on reruns via config_value(). Lives outside Hermes's
# own directory (AAAS_HOME/.hermes) — install.sh must never write there,
# since that's where `hermes setup` stores real provider config/secrets.
# Not wired into any systemd EnvironmentFile=; the gateway unit finds
# ~/.hermes/.env on its own via User=aaas, and the watchdog has its own
# separate env file (WATCHDOG_ENV_FILE). Neither file copies from the other.
CONFIG_FILE="${PLATFORM_DIR}/.env"

# Watchdog-owned env file, currently just HERMES_GATEWAY_UNIT. Deliberately
# separate from CONFIG_FILE and from Hermes's ~/.hermes/.env.
WATCHDOG_ENV_FILE="${WATCHDOG_DIR}/.env"

AAAS_REPO_URL="${AAAS_REPO_URL:-https://github.com/jasonlaw/aaas.git}"
AAAS_REPO_REF="${AAAS_REPO_REF:-master}"
HERMES_OFFICIAL_INSTALL_URL="${HERMES_OFFICIAL_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
LOG_FILE="${WATCHDOG_DIR}/watchdog.log"
ALERT_DIR="${WATCHDOG_DIR}/alerts"

# Dedicated service account that owns all AaaS files and runs all services.
AAAS_USER="aaas"
AAAS_GROUP="aaas"
# Resolved after ensure_aaas_user() runs — always derived from /etc/passwd,
# correct whether aaas was just created or already existed.
AAAS_HOME=""
LOGIN_USER="${SUDO_USER:-${USER:-$(id -un)}}"

# If already running as aaas (e.g. WSL default user), give it an
# interactive shell. Otherwise aaas is a background service account and
# nologin is the safer default. This only decides shell at *creation*
# time — see ensure_aaas_user() for why an existing account's shell is
# only ever upgraded, never downgraded.
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

# Root-only operations (package installs, systemd units, /usr/local/bin
# symlink, useradd/usermod) go through sudo. Everything operating on files
# under ROOT_DIR runs as AAAS_USER via run_as_aaas / sudo -u aaas.
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

trap 'fail "Installation stopped near line ${LINENO}."' ERR

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
  local file="${2:-$CONFIG_FILE}"

  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- || true
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

# Install-time alert helper (distinct from the watchdog's own alert() —
# this one fires from install.sh itself, e.g. if the gateway fails
# verification during install). Kept simple/standalone for now.
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
  nohup run_as_aaas "$@" >>"$LOG_FILE" 2>&1 &
  sleep 3

  process_running "$pattern"
}

# Create dir owned by aaas:aaas with group-write, so both the service
# account and members of the aaas group can write to it.
ensure_owned_dir() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    if ! run_as_aaas mkdir -p "$dir" 2>/dev/null; then
      [[ -n "$SUDO" ]] || fail "Cannot create $dir. Rerun as root or install sudo."
      run $SUDO mkdir -p "$dir"
    fi
  fi

  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$dir"
  run $SUDO chmod 2775 "$dir"   # setgid: new files inherit aaas group

  ok "Directory ready (owned by ${AAAS_USER}:${AAAS_GROUP}): $dir"
}

# ---------------------------------------------------------------------------
# Dedicated service account
# ---------------------------------------------------------------------------

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
    # Only ever upgrade the shell (nologin -> bash), and only when we're
    # currently running as aaas ourselves. Never downgrade an existing
    # shell — aaas may already be a real interactive account (e.g. WSL's
    # pre-created default user), and a different login user rerunning
    # this installer must not silently lock that account to nologin.
    local current_shell
    current_shell="$(getent passwd "$AAAS_USER" | cut -d: -f7)"
    if [[ "$LOGIN_USER" == "$AAAS_USER" && "$current_shell" != "/bin/bash" ]]; then
      run $SUDO usermod --shell "/bin/bash" "$AAAS_USER"
      ok "Updated ${AAAS_USER} shell: ${current_shell} → /bin/bash."
    elif [[ "$current_shell" != "$AAAS_SHELL" ]]; then
      ok "Leaving existing ${AAAS_USER} shell (${current_shell}) unchanged."
    fi
  fi

  # Always derive from /etc/passwd — correct whether aaas was just
  # created with --home-dir ROOT_DIR, or already existed with a
  # different home (e.g. WSL pre-created aaas with /home/aaas).
  AAAS_HOME="$(getent passwd "$AAAS_USER" | cut -d: -f6)"
  [[ -n "$AAAS_HOME" ]] || fail "Cannot determine home directory for ${AAAS_USER} from /etc/passwd."
  ok "Resolved ${AAAS_USER} home: ${AAAS_HOME}."

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

# Ensure ~/.bash_profile sources .bashrc so that `bash -li` (login shell)
# reliably loads PATH entries the Hermes installer wrote into .bashrc.
# Without this, bash -li sources /etc/profile and ~/.bash_profile only —
# not ~/.bashrc — so the Hermes bin dir is invisible to login shells.
ensure_aaas_profile() {
  local profile="${AAAS_HOME}/.bash_profile"
  local marker="# AaaS: source .bashrc for login shells"

  if [[ -f "$profile" ]] && grep -Fq "$marker" "$profile" 2>/dev/null; then
    ok "${profile} already sources .bashrc."
    return
  fi

  printf '\n%s\n%s\n' "$marker" '[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc"' \
    | run_as_aaas tee -a "$profile" >/dev/null
  ok "Updated ${profile} to source .bashrc for login shells."
}

# Directories install.sh itself needs up front. Must run after
# ensure_aaas_user (AAAS_HOME resolved there). Directories created later
# by Hermes/opencode/Docker themselves are provisioned by those tools.
provision_aaas_directories() {
  step "Provisioning AaaS directory layout"

  local dir
  local dirs=(
    "$ROOT_DIR"
    "$PLATFORM_DIR"
    "${AAAS_HOME}/.hermes"
    "${AAAS_HOME}/.hermes/skills"
    "$WATCHDOG_DIR"
  )

  for dir in "${dirs[@]}"; do
    ensure_owned_dir "$dir"
  done
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

install_base_packages() {
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

  [[ -d "$ROOT_DIR" ]] || run $SUDO mkdir -p "$ROOT_DIR"
  ok "Base tools are ready."
}

install_node() {
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

install_opencode() {
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
install_python_yaml() {
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

install_docker() {
  step "Installing Docker Engine"

  if have docker; then
    ok "Docker is already available."
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

  if getent group docker >/dev/null 2>&1; then
    if ! id -nG "$AAAS_USER" 2>/dev/null | grep -qw docker; then
      run $SUDO usermod -aG docker "$AAAS_USER"
      ok "Added ${AAAS_USER} to the docker group."
    fi
  fi

  have docker && ok "Docker is installed." || warn "Docker still needs manual installation."
}

# ---------------------------------------------------------------------------
# ensure_telegram_ipv4_fallback — some hosts resolve api.telegram.org to an
# IPv6 address with no working route (WSL, some cloud VMs, blocked egress),
# hanging the Telegram gateway adapter on connect instead of falling back.
# Probes real IPv6 reachability rather than checking for WSL specifically,
# and pins IPv4 in /etc/hosts only if the probe fails.
# ---------------------------------------------------------------------------
ensure_telegram_ipv4_fallback() {
  step "Checking IPv6 reachability to api.telegram.org"

  if grep -qE '^\s*[0-9.]+\s+api\.telegram\.org\b' /etc/hosts 2>/dev/null; then
    ok "api.telegram.org is already pinned in /etc/hosts."
    return 0
  fi

  have python3 || { warn "python3 not available; skipping the Telegram IPv6 reachability check."; return 0; }

  # Exit code from the probe: 0 = fine or not applicable (no fix needed),
  # 1 = IPv6 resolves but doesn't actually connect (fix needed).
  if python3 - <<'PYEOF'
import socket
import sys

try:
    infos = socket.getaddrinfo("api.telegram.org", 443, socket.AF_INET6)
except socket.gaierror:
    # No AAAA record at all — nothing to work around, IPv4 will be used.
    sys.exit(0)

addr = infos[0][4]
try:
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(addr)
    s.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
  then
    ok "IPv6 to api.telegram.org is reachable; no pin needed."
    return 0
  fi

  warn "api.telegram.org resolves to IPv6 but isn't actually reachable over it (seen on WSL, but can affect any host with broken IPv6 egress). Pinning IPv4 as a workaround."

  local ipv4
  ipv4="$(python3 -c "import socket; print(socket.getaddrinfo('api.telegram.org', 443, socket.AF_INET)[0][4][0])" 2>/dev/null || true)"

  if [[ -z "$ipv4" ]]; then
    warn "Could not resolve api.telegram.org over IPv4 either; skipping the pin. If the Telegram gateway adapter hangs in a restart loop, resolve it manually and add it to /etc/hosts."
    return 0
  fi

  printf "%s api.telegram.org\n" "$ipv4" | $SUDO tee -a /etc/hosts >/dev/null
  ok "Pinned api.telegram.org -> ${ipv4} in /etc/hosts (works around the broken IPv6 path)."
}


#
# Single source of truth for every platform-repo file install.sh either
# requires to exist (MANDATORY_BOOTSTRAP_FILES) or resolves __PLACEHOLDER__
# tokens in (PLACEHOLDER_RESOLVE_FILES). Paths relative to PLATFORM_DIR.
#
# MANDATORY_BOOTSTRAP_FILES: install.sh hard-fails if any are missing after
# sync_platform_files. Reserve this for files whose absence would silently
# break a feature (e.g. a recovery skill: without it, watchdog alerts still
# fire but opencode has no documented recovery procedure to follow).
#
# PLACEHOLDER_RESOLVE_FILES: best-effort — missing files are skipped with a
# warning, not a failure, since some are optional/staged bootstrap files
# (config.yaml, SOUL.md) a given deployment may simply not provide.
# ---------------------------------------------------------------------------
declare -a MANDATORY_BOOTSTRAP_FILES=(
  "watchdog/watchdog.sh"
  "watchdog/watchdog.service"
  ".opencode/skills/hermes-gateway-recovery/SKILL.md"
  ".opencode/skills/watchdog-alert/SKILL.md"
)

declare -a PLACEHOLDER_RESOLVE_FILES=(
  "watchdog/watchdog.sh"
  "watchdog/watchdog.service"
  ".hermes/config.yaml"
  ".hermes/SOUL.md"
  ".opencode/skills/hermes-gateway-recovery/SKILL.md"
)

declare -A BOOTSTRAP_PLACEHOLDERS=()

# Must run after ensure_aaas_user (AAAS_HOME only resolved there).
build_bootstrap_placeholder_table() {
  BOOTSTRAP_PLACEHOLDERS=(
    ["__ROOT_DIR__"]="$ROOT_DIR"
    ["__PLATFORM_DIR__"]="$PLATFORM_DIR"
    ["__HERMES_HOME__"]="${AAAS_HOME}/.hermes"
    ["__AAAS_USER__"]="$AAAS_USER"
    ["__AAAS_GROUP__"]="$AAAS_GROUP"
    ["__CONFIG_FILE__"]="$CONFIG_FILE"
    ["__WATCHDOG_DIR__"]="$WATCHDOG_DIR"
    ["__WATCHDOG_ENV_FILE__"]="$WATCHDOG_ENV_FILE"
    ["__ALERT_DIR__"]="$ALERT_DIR"
  )
}

validate_mandatory_bootstrap_files() {
  step "Validating mandatory platform bootstrap files"

  local rel missing=()
  for rel in "${MANDATORY_BOOTSTRAP_FILES[@]}"; do
    if [[ -f "${PLATFORM_DIR}/${rel}" ]]; then
      ok "Found mandatory bootstrap file: ${rel}"
    else
      missing+=("$rel")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    fail "Missing mandatory platform bootstrap file(s): ${missing[*]}. Add them to the aaas repo under platform/ before rerunning."
  fi
}

# Resolves every __PLACEHOLDER__ token in a single file, in place.
resolve_placeholders_in_file() {
  local file="$1"
  local key sed_args=()

  for key in "${!BOOTSTRAP_PLACEHOLDERS[@]}"; do
    sed_args+=(-e "s|${key}|${BOOTSTRAP_PLACEHOLDERS[$key]}|g")
  done

  run_as_aaas sed -i "${sed_args[@]}" "$file"
}

# Loops PLACEHOLDER_RESOLVE_FILES and resolves any __PLACEHOLDER__ tokens
# found, in place. Safe to rerun: files with no remaining placeholders are
# left untouched.
resolve_all_bootstrap_placeholders() {
  step "Resolving placeholders in bootstrap files"

  local rel file
  for rel in "${PLACEHOLDER_RESOLVE_FILES[@]}"; do
    file="${PLATFORM_DIR}/${rel}"

    if [[ ! -f "$file" ]]; then
      warn "Bootstrap file not found, skipping placeholder resolution: ${rel}"
      continue
    fi

    if grep -qE '__[A-Z_]+__' "$file"; then
      resolve_placeholders_in_file "$file"
      ok "Resolved placeholders in ${rel}"
    else
      ok "No unresolved placeholders in ${rel}; leaving as-is."
    fi

    run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$file"
  done
}

# resolve_gateway_unit_placeholder — resolve __HERMES_GATEWAY_UNIT__ once
# its value is actually known. Not part of the main resolve_all_bootstrap_
# placeholders pass: the gateway's systemd unit name doesn't exist until
# `hermes gateway install --system` runs, well after that pass. Adds the
# now-known value to the shared table and re-runs the generic resolver —
# resolve_placeholders_in_file() is a no-op on files with no remaining
# tokens, so this is safe to call after the first pass has already run.
resolve_gateway_unit_placeholder() {
  local unit_name="$1"
  BOOTSTRAP_PLACEHOLDERS["__HERMES_GATEWAY_UNIT__"]="$unit_name"
  resolve_all_bootstrap_placeholders
}

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

  run $SUDO chown -R "$AAAS_USER:$AAAS_GROUP" "${AAAS_HOME}/.hermes"
  run $SUDO chmod -R g+rX "${AAAS_HOME}/.hermes"

  run_as_aaas bash -li -c "command -v hermes >/dev/null 2>&1" \
    || fail "hermes is not on PATH for ${AAAS_USER} after install. Fix Hermes install, then rerun install.sh."
  ensure_hermes_wrapper

  # Written to PLATFORM_DIR/.env, not AAAS_HOME/.hermes/.env — install.sh
  # never touches Hermes's own directory. HERMES_REAL_BIN is persisted so
  # the watchdog (a separate process started later by systemd) can call
  # the real hermes binary directly, bypassing the guard wrapper the same
  # way verify_hermes_runtime() does.
  run_as_aaas bash -c "cat >\"$CONFIG_FILE\"" <<EOF
# Generated by install.sh
AAAS_ROOT=${ROOT_DIR}
HERMES_REAL_BIN=${HERMES_REAL_BIN}
EOF
  run $SUDO chmod 660 "$CONFIG_FILE"
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# configure_hermes_platform — apply platform bootstrap files (config.yaml,
# SOUL.md) onto an already-installed Hermes. Deliberately separate from
# install_hermes(): this is platform configuration, not installation — it
# runs once all components are present and __PLACEHOLDER__ tokens are
# resolved, and it's the natural place to add more platform-level Hermes
# configuration steps in future without touching install_hermes() itself.
# ---------------------------------------------------------------------------
configure_hermes_platform() {
  step "Applying platform configuration to Hermes"

  write_hermes_config_yaml
  apply_hermes_soul_bootstrap

  warn "Provider, model, fallback, and Telegram are not configured yet."
  warn "Run: sudo -u ${AAAS_USER} hermes setup"
}

# Guard wrapper at /usr/local/bin/hermes: allows the command through only
# when running as aaas, blocks anyone else with a clear error.
HERMES_BIN=""
HERMES_REAL_BIN=""
ensure_hermes_wrapper() {
  local real_bin wrapper="/usr/local/bin/hermes"

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

# ---------------------------------------------------------------------------
# ensure_watchdog_sudo — scoped, passwordless sudo for aaas to run ONLY
# "$HERMES_REAL_BIN gateway ..." as root. Used for diagnostics only (e.g.
# `hermes gateway status --system`) — the actual restart/health-check path
# goes through systemctl directly (see ensure_watchdog_systemctl_sudo),
# since the hermes CLI's guard wrapper (blocks non-aaas) and the --system
# subcommands' root requirement can never both be satisfied by one process.
#
# Scoped to the exact resolved binary path plus a literal "gateway"
# subcommand, so a compromised watchdog process can't sudo anything else.
# ---------------------------------------------------------------------------
ensure_watchdog_sudo() {
  step "Granting scoped sudo for Hermes gateway control (diagnostics)"

  [[ -n "$HERMES_REAL_BIN" ]] || fail "HERMES_REAL_BIN is not set. ensure_hermes_wrapper must run before ensure_watchdog_sudo."
  [[ -n "$SUDO" || "${EUID:-$(id -u)}" -eq 0 ]] || fail "Granting sudo rules requires root or sudo."
  have visudo || fail "visudo is required to safely install the watchdog sudoers rule."

  local sudoers_file="/etc/sudoers.d/aaas-hermes-gateway"
  local rule="${AAAS_USER} ALL=(root) NOPASSWD: ${HERMES_REAL_BIN} gateway *"
  local tmp_sudoers
  tmp_sudoers="$(mktemp)"

  if [[ -f "$sudoers_file" ]] && grep -Fxq "$rule" "$sudoers_file" 2>/dev/null; then
    ok "Sudoers rule already present and matches current Hermes binary path."
    rm -f "$tmp_sudoers"
    return
  fi

  printf '%s\n' "$rule" >"$tmp_sudoers"
  chmod 0440 "$tmp_sudoers"

  if ! $SUDO visudo -cf "$tmp_sudoers" >/dev/null 2>&1; then
    rm -f "$tmp_sudoers"
    fail "Generated sudoers rule failed visudo syntax check; not installed."
  fi

  run $SUDO install -m 0440 -o root -g root "$tmp_sudoers" "$sudoers_file"
  rm -f "$tmp_sudoers"
  ok "Installed scoped sudoers rule at ${sudoers_file}."
  ok "aaas may now run: sudo ${HERMES_REAL_BIN} gateway <start|stop|restart|status> --system (NOPASSWD, diagnostics only)."
}

# ---------------------------------------------------------------------------
# ensure_watchdog_systemctl_sudo — scoped, passwordless sudo for aaas to
# run ONLY `systemctl {start,stop,restart,is-active,status} <exact-unit>`
# as root. This is the PRIMARY mechanism watchdog.sh, the recovery skill,
# and summary() use to control the Hermes gateway service, sidestepping
# the wrapper-vs-root conflict noted above.
#
# Scoped to the exact unit name (not a wildcard), so a compromised
# watchdog process can't restart/stop arbitrary services. Call only after
# the unit name is known (i.e. after `hermes gateway install --system`).
# ---------------------------------------------------------------------------
ensure_watchdog_systemctl_sudo() {
  local unit_name="$1"
  step "Granting scoped sudo for systemctl control of ${unit_name}"

  [[ -n "$SUDO" || "${EUID:-$(id -u)}" -eq 0 ]] || fail "Granting sudo rules requires root or sudo."
  have visudo || fail "visudo is required to safely install the watchdog sudoers rule."

  local systemctl_bin
  systemctl_bin="$(command -v systemctl)"
  [[ -n "$systemctl_bin" ]] || fail "Could not resolve the systemctl binary path."

  local sudoers_file="/etc/sudoers.d/aaas-hermes-gateway-systemctl"
  local rule="${AAAS_USER} ALL=(root) NOPASSWD: ${systemctl_bin} start ${unit_name}, ${systemctl_bin} stop ${unit_name}, ${systemctl_bin} restart ${unit_name}, ${systemctl_bin} status ${unit_name}, ${systemctl_bin} is-active ${unit_name}"
  local tmp_sudoers
  tmp_sudoers="$(mktemp)"

  if [[ -f "$sudoers_file" ]] && grep -Fxq "$rule" "$sudoers_file" 2>/dev/null; then
    ok "Sudoers rule already present and matches the current gateway unit name."
    rm -f "$tmp_sudoers"
    return
  fi

  printf '%s\n' "$rule" >"$tmp_sudoers"
  chmod 0440 "$tmp_sudoers"

  if ! $SUDO visudo -cf "$tmp_sudoers" >/dev/null 2>&1; then
    rm -f "$tmp_sudoers"
    fail "Generated sudoers rule failed visudo syntax check; not installed."
  fi

  run $SUDO install -m 0440 -o root -g root "$tmp_sudoers" "$sudoers_file"
  rm -f "$tmp_sudoers"
  ok "Installed scoped sudoers rule at ${sudoers_file}."
  ok "aaas may now run: sudo systemctl <start|stop|restart|status|is-active> ${unit_name} (NOPASSWD)."
}

# ---------------------------------------------------------------------------
# Applies PLATFORM_DIR/.hermes/config.yaml onto Hermes's generated
# config.yaml via a real YAML parse/merge (not text-append). Per-key merge
# behavior is controlled by an optional trailing directive comment:
#
#   provider: mnemosyne     # @force     (default if no directive given)
#   fallback: openai        # @default
#   telegram:               # @disable
#
#   @force    — always overwrite this key with the bootstrap value.
#   @default  — only set if missing from the real config; never clobber.
#   @disable  — always comment out this key in the final config.yaml
#               (top-level keys only).
#
# All three are idempotent by construction, so no "consumed" bookkeeping
# is needed.
# ---------------------------------------------------------------------------
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

bootstrap = yaml.safe_load(bootstrap_text) or {}

DIRECTIVE_RE = re.compile(r'#\s*@(force|default|disable)\b')
KEY_RE = re.compile(r'^(?P<indent>[ \t]*)(?P<key>[A-Za-z0-9_.-]+):')

directive_map = {}
stack = []
for line in bootstrap_text.splitlines():
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    m = KEY_RE.match(line)
    if not m:
        continue
    indent = len(m.group('indent'))
    key = m.group('key')
    while stack and stack[-1][0] >= indent:
        stack.pop()
    dotted = '.'.join([k for _, k in stack] + [key])
    stack.append((indent, key))
    dm = DIRECTIVE_RE.search(line)
    if dm:
        directive_map[dotted] = dm.group(1)

disabled_paths = []

def merge_node(cfg_node, bootstrap_node, path_prefix):
    for key, bvalue in bootstrap_node.items():
        path = f"{path_prefix}.{key}" if path_prefix else key
        directive = directive_map.get(path)

        if directive == 'disable':
            disabled_paths.append(path)
            continue

        if directive == 'default':
            if key not in cfg_node:
                cfg_node[key] = bvalue
            continue

        if isinstance(bvalue, dict) and directive is None and isinstance(cfg_node.get(key), dict):
            merge_node(cfg_node[key], bvalue, path)
        else:
            cfg_node[key] = bvalue

merge_node(cfg, bootstrap, '')

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

top_level_disabled = sorted({p for p in disabled_paths if '.' not in p})
for p in disabled_paths:
    if '.' in p:
        print(f"WARNING: nested @disable on '{p}' is not supported for comment-out rendering; ignoring.", file=sys.stderr)

for key in top_level_disabled:
    dumped = comment_out_block(dumped, key)

with open(path, "w") as f:
    f.write(dumped)
PYEOF

  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$hermes_config"
  run $SUDO chmod 660 "$hermes_config"

  ok "Applied .hermes/config.yaml to config.yaml."
}

# Copies PLATFORM_DIR/.hermes/SOUL.md over AAAS_HOME/.hermes/SOUL.md.
# SOUL.md is static and freshly read by Hermes each session, so it's
# always safe to overwrite unconditionally on every run — no merge
# semantics needed, unlike config.yaml.
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

  ok "Applied .hermes/SOUL.md to SOUL.md (overwritten)."
}

# ---------------------------------------------------------------------------
# ensure_venv_ensurepip_support — make sure `python3 -m venv` actually
# produces a venv with a working pip (its --help succeeds regardless, so
# it can't be used to detect this; we create a throwaway venv instead).
#
# On Debian/Ubuntu, ensurepip support ships in a version-specific package
# (e.g. python3.14-venv), not always covered by generic "python3-venv" if
# python3 is newer than the distro default. Try version-specific first.
# ---------------------------------------------------------------------------
ensure_venv_ensurepip_support() {
  local probe_dir

  probe_dir="$(mktemp -d)"
  if python3 -m venv "${probe_dir}/probe" >/dev/null 2>&1 \
     && [[ -x "${probe_dir}/probe/bin/pip" || -x "${probe_dir}/probe/bin/pip3" ]]; then
    rm -rf "$probe_dir"
    return 0
  fi
  rm -rf "$probe_dir"

  case "$(detect_pm)" in
    apt)
      local pyver pkg
      pyver="$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
      pkg="python3.${pyver#3.}-venv"
      run_apt update
      if ! run_apt install -y "$pkg" 2>/dev/null; then
        warn "Package ${pkg} not found; falling back to python3-venv."
        run_apt install -y python3-venv
      fi
      ;;
    dnf)
      run $SUDO dnf install -y python3-virtualenv || true
      ;;
    yum)
      run $SUDO yum install -y python3-virtualenv || true
      ;;
    pacman|brew)
      ok "$(detect_pm)-based python3 should already include venv/ensurepip support."
      ;;
    *)
      warn "Could not determine package manager; install venv/ensurepip support for python3 manually."
      ;;
  esac

  probe_dir="$(mktemp -d)"
  if python3 -m venv "${probe_dir}/probe" >/dev/null 2>&1 \
     && [[ -x "${probe_dir}/probe/bin/pip" || -x "${probe_dir}/probe/bin/pip3" ]]; then
    rm -rf "$probe_dir"
    ok "python3 -m venv now produces a working pip."
  else
    rm -rf "$probe_dir"
    fail "python3 -m venv still cannot bootstrap pip. Install manually: apt install python3-venv (or the python3.X-venv matching '$(python3 --version)')."
  fi
}

# ---------------------------------------------------------------------------
# Install Mnemosyne as Hermes's sole memory provider, into a dedicated
# standalone venv (never into Hermes's own managed venv — `hermes update`
# rebuilds that and would wipe anything installed there directly).
#
# Registration uses `mnemosyne-hermes install --mode wrapper --python
# <standalone-venv-python> --no-bootstrap`: creates a persistent shim
# under Hermes's plugins directory that imports mnemosyne_hermes from our
# standalone venv, so nothing needs installing into Hermes's own venv.
# --no-bootstrap guarantees the tool's own profile-ignorant auto-bootstrap
# never fires as a side effect.
#
# The platform/.hermes/config.yaml bootstrap must set:
#   memory:
#     memory_enabled: false        — disables built-in MEMORY.md injection
#     user_profile_enabled: false  — disables built-in USER.md injection
#     provider: mnemosyne
#
# IMPORTANT: do NOT use `hermes tools disable memory` — that also kills
# all Mnemosyne-registered tools. Use memory_enabled: false instead.
#
# MNEMOSYNE_HOST_LLM_ENABLED routes consolidation LLM calls through
# Hermes's own authenticated provider — no separate API key needed. Does
# NOT cover embeddings; those need a local model (embeddings/all profile)
# or MNEMOSYNE_EMBEDDING_API_URL.
#
# Data lives at ~/.hermes/mnemosyne/data/ (upstream default).
#
# Install profile via MNEMOSYNE_INSTALL_PROFILE env var:
#   unset / "embeddings" → local fastembed model, ~800 MB (default)
#   "all"                → mnemosyne-memory[all], ~1.5 GB, 8 GB+ RAM
#   (empty/core has no local embedding backend — needs
#    MNEMOSYNE_EMBEDDING_API_URL or semantic recall degrades)
# ---------------------------------------------------------------------------
install_mnemosyne() {
  step "Installing Mnemosyne memory provider"

  local mnemosyne_venv="${AAAS_HOME}/.hermes/mnemosyne-venv"
  local venv_python="${mnemosyne_venv}/bin/python"
  local hermes_env="${AAAS_HOME}/.hermes/.env"
  local profile="${MNEMOSYNE_INSTALL_PROFILE:-embeddings}"

  ensure_venv_ensurepip_support

  # Idempotency guard: a venv only counts as "already good" if pip
  # actually works in it — a prior failed attempt can leave bin/python3
  # present but no working pip.
  if [[ -x "$venv_python" ]] && run_as_aaas "$venv_python" -m pip --version >/dev/null 2>&1; then
    ok "Mnemosyne standalone venv already exists and has working pip at ${mnemosyne_venv}."
  else
    if [[ -d "$mnemosyne_venv" ]]; then
      warn "Existing mnemosyne-venv at ${mnemosyne_venv} is broken (no working pip); recreating."
      run_as_aaas rm -rf "$mnemosyne_venv"
    fi
    install_banner "mnemosyne standalone venv"
    run_as_aaas python3 -m venv "$mnemosyne_venv" \
      || fail "Failed to create venv at ${mnemosyne_venv} even after installing venv support."
    run_as_aaas "$venv_python" -m ensurepip --upgrade \
      || fail "python3 -m venv succeeded but ensurepip still failed inside ${mnemosyne_venv}. Check python3-venv / python3-pip installation."
    ok "Created standalone venv at ${mnemosyne_venv}."
  fi

  run_as_aaas "$venv_python" -m pip install --quiet --upgrade pip

  local core_pkg
  if [[ -n "$profile" ]]; then
    core_pkg="mnemosyne-memory[${profile}]"
  else
    core_pkg="mnemosyne-memory"
  fi

  local installed_core_ver installed_hermes_ver
  installed_core_ver="$(run_as_aaas "$venv_python" -m pip show mnemosyne-memory 2>/dev/null | awk '/^Version:/ {print $2}' || true)"
  installed_hermes_ver="$(run_as_aaas "$venv_python" -m pip show mnemosyne-hermes 2>/dev/null | awk '/^Version:/ {print $2}' || true)"

  if [[ -n "$installed_core_ver" && -n "$installed_hermes_ver" ]]; then
    ok "mnemosyne-memory ${installed_core_ver} and mnemosyne-hermes ${installed_hermes_ver} already installed in the standalone venv; skipping."
  else
    install_banner "mnemosyne (${core_pkg} + mnemosyne-hermes) in standalone venv"
    run_as_aaas "$venv_python" -m pip install --quiet --upgrade "$core_pkg" mnemosyne-hermes
    ok "Installed ${core_pkg} and mnemosyne-hermes into ${mnemosyne_venv}."
  fi

  run_as_aaas "${mnemosyne_venv}/bin/mnemosyne-hermes" \
    --hermes-home "${AAAS_HOME}/.hermes" \
    install --force --no-bootstrap --mode wrapper --python "$venv_python" \
    || fail "mnemosyne-hermes install --mode wrapper failed. Run 'sudo -u ${AAAS_USER} ${mnemosyne_venv}/bin/mnemosyne-hermes --hermes-home ${AAAS_HOME}/.hermes install --dry-run --mode wrapper --python ${venv_python}' to inspect."
  ok "Registered the mnemosyne plugin with Hermes (wrapper mode, no changes made to Hermes's own venv)."

  run_as_aaas bash -li -c "hermes config set memory.provider mnemosyne"
  ok "memory.provider set to mnemosyne in Hermes config."

  if grep -Fq "MNEMOSYNE_HOST_LLM_ENABLED" "$hermes_env" 2>/dev/null; then
    ok "MNEMOSYNE_HOST_LLM_ENABLED already set in ${hermes_env}."
  else
    printf "MNEMOSYNE_HOST_LLM_ENABLED=true\n" | run_as_aaas tee -a "$hermes_env" >/dev/null
    ok "MNEMOSYNE_HOST_LLM_ENABLED=true written to ${hermes_env}."
  fi

  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$hermes_env"
  run $SUDO chmod 660 "$hermes_env"

  ok "Mnemosyne install complete (standalone venv: ${mnemosyne_venv}, profile: ${profile:-core})."
  ok "Data will live at ${AAAS_HOME}/.hermes/mnemosyne/data/"
  warn "After gateway restart, verify with:"
  warn "  sudo -u ${AAAS_USER} ${mnemosyne_venv}/bin/mnemosyne-hermes --hermes-home ${AAAS_HOME}/.hermes status"
  warn "  sudo -u ${AAAS_USER} hermes mnemosyne stats"
  warn "  sudo -u ${AAAS_USER} hermes doctor | grep -A5 'Memory Provider'   # (unconfirmed grep pattern — check actual doctor output if this doesn't match)"
}

write_watchdog() {
  step "Preparing the watchdog"

  # Both watchdog.sh and watchdog.service are static repo files under
  # platform/watchdog/, delivered straight to ${WATCHDOG_DIR} by
  # sync_platform_files() (WATCHDOG_DIR is literally ${PLATFORM_DIR}/watchdog)
  # and __PLACEHOLDER__-resolved by resolve_all_bootstrap_placeholders()
  # earlier in main(). install.sh only needs to verify they landed and fix
  # permissions — changing watchdog behavior or its systemd unit is a pure
  # repo-file edit from here on.
  local watchdog_script="${WATCHDOG_DIR}/watchdog.sh"
  local watchdog_unit_file="${WATCHDOG_DIR}/watchdog.service"

  [[ -f "$watchdog_script" ]] || fail "watchdog.sh not found at ${watchdog_script}. It should have been synced from the platform repo."
  [[ -f "$watchdog_unit_file" ]] || fail "watchdog.service not found at ${watchdog_unit_file}. It should have been synced from the platform repo."

  run $SUDO chmod +x "$watchdog_script"
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$watchdog_script" "$watchdog_unit_file"
  ok "Watchdog script and systemd unit ready under ${WATCHDOG_DIR}."
}

# resolve_hermes_gateway_unit_name — find the systemd unit name that
# `hermes gateway install --system` generated. Shared by
# configure_hermes_gateway_service_env and verify_hermes_runtime.
#
# Captures systemctl's output into a variable first, then feeds it to awk
# via a here-string rather than a live pipe. Piping directly into
# `awk '{ ...; exit }'` is racy under `set -o pipefail`: awk's early exit
# can close the pipe while systemctl is still writing, killing it with
# SIGPIPE — a non-zero exit status that pipefail then blames on the whole
# pipeline, even though awk already got the answer. Capturing first avoids
# a live producer/consumer pipe entirely.
resolve_hermes_gateway_unit_name() {
  local unit_files
  unit_files="$($SUDO systemctl list-unit-files --type=service --no-legend 2>/dev/null || true)"
  awk '$1 ~ /hermes/ && $1 ~ /gateway/ { print $1; exit }' <<<"$unit_files"
}

configure_hermes_gateway_service_env() {
  local unit_name dropin_dir dropin_file

  unit_name="$(resolve_hermes_gateway_unit_name)"

  if [[ -z "$unit_name" ]]; then
    warn "Could not find the installed Hermes gateway systemd unit. It may need a manual service override."
    return
  fi

  dropin_dir="/etc/systemd/system/${unit_name}.d"
  dropin_file="${dropin_dir}/aaas.conf"

  run $SUDO mkdir -p "$dropin_dir"
  # Run the gateway as aaas:aaas. With User=aaas, systemd resolves $HOME
  # from /etc/passwd automatically, so Hermes finds ~/.hermes/.env at its
  # default location without any extra env vars. Do NOT add an
  # EnvironmentFile= here — neither the platform .env nor the watchdog's
  # env file belong in the gateway's process environment.
  printf "[Service]\nUser=%s\nGroup=%s\n" \
    "$AAAS_USER" "$AAAS_GROUP" \
    | $SUDO tee "$dropin_file" >/dev/null
  run $SUDO systemctl daemon-reload
  ok "Hermes gateway service ${unit_name} pinned to ${AAAS_USER}:${AAAS_GROUP} (reads its own ~/.hermes/.env; no EnvironmentFile override)."
}

# persist_hermes_gateway_unit — write HERMES_GATEWAY_UNIT into
# WATCHDOG_ENV_FILE so watchdog.sh, the recovery skill, and summary() can
# all reference the resolved unit name via `systemctl <verb> <unit>`,
# without going through the hermes CLI/guard wrapper.
persist_hermes_gateway_unit() {
  local unit_name="$1"

  if [[ ! -f "$WATCHDOG_ENV_FILE" ]]; then
    run_as_aaas bash -c "cat > '${WATCHDOG_ENV_FILE}'" <<EOF
# Generated by install.sh — watchdog-only settings.
# Deliberately separate from ${CONFIG_FILE} and from Hermes's own
# ~/.hermes/.env. Nothing here is copied to or from either of those.
EOF
  fi

  if grep -q '^HERMES_GATEWAY_UNIT=' "$WATCHDOG_ENV_FILE" 2>/dev/null; then
    run_as_aaas sed -i "s|^HERMES_GATEWAY_UNIT=.*|HERMES_GATEWAY_UNIT=${unit_name}|" "$WATCHDOG_ENV_FILE"
  else
    printf "HERMES_GATEWAY_UNIT=%s\n" "$unit_name" | run_as_aaas tee -a "$WATCHDOG_ENV_FILE" >/dev/null
  fi
  run $SUDO chown "$AAAS_USER:$AAAS_GROUP" "$WATCHDOG_ENV_FILE"
  run $SUDO chmod 660 "$WATCHDOG_ENV_FILE"
  ok "Persisted HERMES_GATEWAY_UNIT=${unit_name} to ${WATCHDOG_ENV_FILE}."
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

    # gateway install is a one-time setup step — bypasses the wrapper
    # guard directly, since it needs the real binary.
    run $SUDO "$HERMES_REAL_BIN" gateway install --system
    configure_hermes_gateway_service_env

    local unit_name
    unit_name="$(resolve_hermes_gateway_unit_name)"
    [[ -n "$unit_name" ]] || fail "Could not resolve the Hermes gateway systemd unit name after install."
    persist_hermes_gateway_unit "$unit_name"
    ensure_watchdog_systemctl_sudo "$unit_name"
    resolve_gateway_unit_placeholder "$unit_name"

    # Health-check and start/restart via systemctl directly, not the
    # hermes CLI — see the wrapper-vs-root note above.
    if ! $SUDO systemctl is-active --quiet "$unit_name"; then
      run $SUDO systemctl start "$unit_name"
    else
      ok "Hermes gateway is already running."
    fi

    if ! $SUDO systemctl is-active --quiet "$unit_name"; then
      write_alert "Hermes gateway system service failed verification"
      fail "Hermes gateway system service is not running. Check: sudo systemctl status ${unit_name}"
    fi
    ok "Hermes gateway system service (${unit_name}) is running as ${AAAS_USER}."
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
  printf "       ${BOLD}sudo -u %s %s/.hermes/mnemosyne-venv/bin/mnemosyne-hermes --hermes-home %s/.hermes status${RESET}\n" "$AAAS_USER" "$AAAS_HOME" "$AAAS_HOME"
  printf "       ${BOLD}sudo -u %s hermes mnemosyne stats${RESET}\n" "$AAAS_USER"
  printf "       ${BOLD}sudo -u %s hermes doctor | grep -A5 'Memory Provider'${RESET}  (unconfirmed grep pattern)\n" "$AAAS_USER"
  printf "\n"
  printf "  3. (Optional) Add a fallback provider for reliability:\n"
  printf "       ${BOLD}sudo -u %s hermes fallback add${RESET}\n" "$AAAS_USER"
  printf "\n"
  printf "  4. (Optional) Configure messaging platform integrations (Telegram, etc.):\n"
  printf "       ${BOLD}sudo -u %s hermes gateway setup${RESET}\n" "$AAAS_USER"
  printf "\n"
  printf "  5. After any configuration change, restart the gateway to apply it:\n"
  printf "       ${BOLD}sudo systemctl restart %s${RESET}\n" "$(config_value HERMES_GATEWAY_UNIT "$WATCHDOG_ENV_FILE")"
  printf "     (this exact unit name is also stored in %s as HERMES_GATEWAY_UNIT)\n" "$WATCHDOG_ENV_FILE"
  printf "\n"
  printf "  6. Mnemosyne install profile is controlled by MNEMOSYNE_INSTALL_PROFILE\n"
  printf "     (default: embeddings, ~800 MB, local semantic recall out of the box).\n"
  printf "     Set to 'all' for a full local LLM (~1.5 GB, 8 GB+ RAM), or unset/empty\n"
  printf "     for core only (~50 MB, requires MNEMOSYNE_EMBEDDING_API_URL for semantic\n"
  printf "     recall) — then rerun install.sh.\n"
  printf "\n"
  printf "%sHermes gateway note:%s\n" "${BOLD}" "${RESET}"
  printf "  The gateway is installed as a systemd system service — starts at boot,\n"
  printf "  runs independently of any user session. Intentional for a server\n"
  printf "  deployment; ignore any Hermes prompt suggesting a per-user service.\n"
  printf "\n"
  printf "%sManual gateway restarts:%s\n" "${BOLD}" "${RESET}"
  printf "  Use systemctl directly, NOT the 'hermes' CLI. The 'hermes' command on PATH\n"
  printf "  is a guard wrapper that blocks anyone who isn't %s, including root — but\n" "$AAAS_USER"
  printf "  gateway control needs root, and a single process can't be both at once:\n"
  printf "    ${BOLD}sudo systemctl restart %s${RESET}\n" "$(config_value HERMES_GATEWAY_UNIT "$WATCHDOG_ENV_FILE")"
  printf "  The watchdog service (aaas-watchdog.service) already does this automatically\n"
  printf "  via a scoped NOPASSWD sudoers rule at /etc/sudoers.d/aaas-hermes-gateway-systemctl,\n"
  printf "  and falls back to invoking opencode with the hermes-gateway-recovery skill if\n"
  printf "  the direct restart attempt fails.\n"
}

main() {
  banner

  # --- Service account & filesystem layout ---------------------------------
  install_base_packages
  ensure_aaas_user            # must run first: resolves AAAS_HOME
  build_bootstrap_placeholder_table
  provision_aaas_directories
  ensure_aaas_profile          # must run before install_hermes

  # --- Platform source & core dependencies ----------------------------------
  sync_platform_files
  validate_mandatory_bootstrap_files
  install_node
  install_opencode
  install_python_yaml
  install_docker
  ensure_telegram_ipv4_fallback
  install_hermes                # binary only — no platform config applied yet

  # --- Platform configuration -------------------------------------------------
  # Placeholders resolved once, right before the files that need them are
  # actually consumed (config.yaml/SOUL.md by configure_hermes_platform).
  # __HERMES_GATEWAY_UNIT__ is the one exception — its value doesn't exist
  # until verify_hermes_runtime, so it's resolved separately there.
  resolve_all_bootstrap_placeholders
  configure_hermes_platform

  # --- Mnemosyne memory ---------------------------------------------------------
  ensure_watchdog_sudo         # needs HERMES_REAL_BIN from install_hermes
  install_mnemosyne

  # --- Watchdog & service wiring ----------------------------------------------
  write_watchdog
  verify_hermes_runtime
  install_watchdog_service

  summary
}

main "$@"