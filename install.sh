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
HERMES_HOME="${PLATFORM_DIR}/.hermes"
WATCHDOG_DIR="${PLATFORM_DIR}/watchdog"
# Platform-owned env file (AAAS_ROOT/HERMES_HOME) consumed by watchdog.sh and
# the systemd units. Deliberately lives outside HERMES_HOME: install.sh must
# never write into Hermes's own directory, since that's where `hermes setup`
# later stores real provider config and secrets.
CONFIG_FILE="${PLATFORM_DIR}/.env"
HERMES_INSTALL_MARKER="${HERMES_HOME}/.installed"
AAAS_REPO_URL="${AAAS_REPO_URL:-https://github.com/jasonlaw/aaas.git}"
AAAS_REPO_REF="${AAAS_REPO_REF:-master}"
HERMES_OFFICIAL_INSTALL_URL="${HERMES_OFFICIAL_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
LOG_FILE="${WATCHDOG_DIR}/watchdog.log"
ALERT_DIR="${WATCHDOG_DIR}/alerts"

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

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

trap 'fail "Installation stopped near line ${LINENO}."' ERR

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
    "$HERMES_HOME/bin"
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
  mkdir -p "$alert_path"
  printf "[%s] %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$message" >"${alert_path}/alert.txt"
  warn "$message"
  if have opencode; then
    opencode run "AaaS installer alert: $message. Inspect ${alert_path}/alert.txt, repair the issue, rerun install.sh if needed, then remove the folder ${alert_path} after picking up this alert." >>"$LOG_FILE" 2>&1 || true
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
  nohup "$@" >>"$LOG_FILE" 2>&1 &
  sleep 3

  process_running "$pattern"
}

ensure_owned_dir() {
  local dir="$1"

  if [[ -d "$dir" ]]; then
    ok "$dir already exists."
    return
  fi

  if mkdir -p "$dir" 2>/dev/null; then
    ok "Created $dir."
    return
  fi

  [[ -n "$SUDO" ]] || fail "Cannot create $dir. Rerun as root or install sudo."
  run $SUDO mkdir -p "$dir"
  run $SUDO chown -R "$(id -u):$(id -g)" "$dir"
  ok "Created $dir."
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
      --exclude='./.hermes/.env' \
      --exclude='./.hermes/.installed' \
      -C "$source_platform" -cf - . | tar -C "$PLATFORM_DIR" -xf -
  else
    cp -a "$source_platform/." "$PLATFORM_DIR/"
  fi

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

  ensure_owned_dir "$ROOT_DIR"
  ensure_owned_dir "$PLATFORM_DIR"
  ensure_owned_dir "$HERMES_HOME"
  ensure_owned_dir "$WATCHDOG_DIR"
  ok "Installation folders are ready."
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

# PyYAML is required to merge skills.external_dirs into whatever config.yaml
# the Hermes setup wizard produces, without clobbering other top-level keys
# (e.g. the wizard's own `skills.creation_nudge_interval`) or introducing
# duplicate YAML keys.
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

  have docker && ok "Docker is installed." || warn "Docker still needs manual installation."
}

# Fully non-interactive Hermes install: --skip-setup skips the wizard
# entirely (no provider/model/Telegram prompts), --non-interactive
# auto-answers any remaining yes/no prompts with defaults, --skip-browser
# skips the Playwright/Chromium step. Provider, model, fallback, and
# Telegram are intentionally NOT configured here — run `hermes config set`
# (or `hermes setup`) by hand after install.sh finishes. HERMES_HOME is
# passed inline on the same command as the install, not just exported,
# since the installer's own bootstrap phase (launcher script, PATH setup)
# doesn't reliably inherit an exported var across the curl | bash pipe.
install_hermes() {
  step "Installing Hermes"

  local install_url
  install_url="${HERMES_INSTALL_URL:-$HERMES_OFFICIAL_INSTALL_URL}"

  refresh_path
  if have hermes && [[ -d "$HERMES_HOME" ]]; then
    ok "Hermes is already available at $(command -v hermes)."
  else
    install_banner "Hermes"
    curl -fsSL "$install_url" | HERMES_HOME="$HERMES_HOME" bash -s -- --skip-setup --non-interactive --skip-browser
    refresh_path
    touch "$HERMES_INSTALL_MARKER"
    ok "Hermes installer finished."
  fi

  have hermes || fail "hermes is not on PATH after install. Fix Hermes install, then rerun install.sh."
  ensure_hermes_symlink
  ensure_hermes_home_env

  # Written to PLATFORM_DIR/.env, not HERMES_HOME/.env — install.sh never
  # touches Hermes's own directory, which is where `hermes setup` later
  # stores real provider config and secrets.
  cat >"$CONFIG_FILE" <<EOF
# Generated by install.sh
AAAS_ROOT=${ROOT_DIR}
HERMES_HOME=${HERMES_HOME}
EOF
  chmod 600 "$CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  write_hermes_config_yaml
  ok "Hermes config.yaml updated: external skills dir merged, provider/model commented out."

  warn "Provider, model, fallback, and Telegram are not configured yet."
  warn "Run: env HERMES_HOME=${HERMES_HOME} hermes setup   (or hermes config set ...)"
}

# install.sh only sets HERMES_HOME for its own process — it doesn't persist
# across future shells. Without this, `hermes` typed manually later falls
# back to its own default ($HOME/.hermes) instead of the platform's home.
# Persist it once, idempotently, into the invoking user's shell profile.
ensure_hermes_home_env() {
  local profile="${HOME}/.bashrc"
  local line="export HERMES_HOME=${HERMES_HOME}"

  if [[ -f "$profile" ]] && grep -Fxq "$line" "$profile"; then
    ok "HERMES_HOME is already persisted in ${profile}."
    return
  fi

  printf "\n# Added by AaaS install.sh\n%s\n" "$line" >>"$profile"
  ok "Persisted HERMES_HOME in ${profile}. Run 'source ${profile}' or open a new shell for it to take effect."
}

# sudo's secure_path strips the invoking user's PATH, so the hermes launcher
# under ~/.local/bin (or $HERMES_HOME/hermes-agent/venv/bin) is invisible to
# `sudo env HERMES_HOME=... hermes ...` even though the current shell can
# find it fine. Symlink it into /usr/local/bin, which sudo always sees, and
# export HERMES_BIN so every sudo call below uses the resolved absolute path
# instead of relying on PATH lookup a second time.
HERMES_BIN=""
ensure_hermes_symlink() {
  local real_bin target="/usr/local/bin/hermes"

  real_bin="$(command -v hermes)" || fail "Cannot resolve hermes binary path."

  if [[ -n "$SUDO" || "${EUID:-$(id -u)}" -eq 0 ]]; then
    if [[ ! -e "$target" || "$(readlink -f "$target" 2>/dev/null)" != "$(readlink -f "$real_bin")" ]]; then
      run $SUDO ln -sf "$real_bin" "$target"
      ok "Symlinked ${target} -> ${real_bin} so sudo can find hermes."
    else
      ok "${target} already points to the current hermes binary."
    fi
    HERMES_BIN="$target"
  else
    warn "No sudo available to symlink hermes into /usr/local/bin; using resolved path directly."
    HERMES_BIN="$real_bin"
  fi
}

# Merges skills.external_dirs into the config.yaml produced by Hermes's own
# setup wizard, via a real YAML parse/merge (not text-append) so we don't
# clobber sibling keys like skills.creation_nudge_interval or create
# duplicate top-level YAML keys. Also comments out any top-level
# provider/model block the Hermes installer may have written on its own —
# install.sh runs Hermes install with --skip-setup deliberately (see
# install_hermes) and shouldn't let a leftover default provider/model get
# picked up silently. Commented rather than deleted so it's a one-line
# uncomment to restore after running `hermes setup` for real.
write_hermes_config_yaml() {
  local hermes_config="${HERMES_HOME}/config.yaml"
  local skills_dir="${PLATFORM_DIR}/.opencode/skills"

  if [[ ! -f "$hermes_config" ]]; then
    warn "config.yaml not found at ${hermes_config}; skipping skills merge."
    return
  fi

  SKILLS_EXTERNAL_DIR="$skills_dir" python3 - "$hermes_config" <<'PYEOF'
import os, re, sys
import yaml

path = sys.argv[1]
skills_dir = os.environ["SKILLS_EXTERNAL_DIR"]

with open(path) as f:
    cfg = yaml.safe_load(f) or {}

cfg.setdefault("skills", {})
existing = cfg["skills"].get("external_dirs") or []
if skills_dir not in existing:
    existing.append(skills_dir)
cfg["skills"]["external_dirs"] = existing

dumped = yaml.dump(cfg, default_flow_style=False, sort_keys=False)

def comment_out_block(text, key):
    """Comment out a top-level `key:` line plus any indented/blank lines
    that belong to it, stopping at the next top-level key or EOF."""
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

for key in ("provider", "model"):
    dumped = comment_out_block(dumped, key)

with open(path, "w") as f:
    f.write(dumped)
PYEOF

  chmod 600 "$hermes_config"
}

write_watchdog() {
  step "Creating the watchdog"

  cat >"${WATCHDOG_DIR}/watchdog.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PLATFORM_DIR}/.env"
ALERT_DIR="${SCRIPT_DIR}/alerts"
LOG_FILE="${SCRIPT_DIR}/watchdog.log"

source "$CONFIG_FILE"

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

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
    opencode run "AaaS watchdog alert: $*. Inspect ${alert_path}/alert.txt, repair Hermes or its gateway, then remove the folder ${alert_path} after picking up this alert." >>"$LOG_FILE" 2>&1 || true
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

if ! $SUDO env HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" gateway status --system >/dev/null 2>&1; then
  log "Hermes gateway system service is not healthy; starting it."
  if ! $SUDO env HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" gateway start --system >>"$LOG_FILE" 2>&1; then
    alert "Failed to start Hermes gateway system service"
    exit 1
  fi
fi

if ! $SUDO env HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" gateway status --system >>"$LOG_FILE" 2>&1; then
  alert "Hermes gateway system service is not running"
  exit 1
fi
EOF

  chmod +x "${WATCHDOG_DIR}/watchdog.sh"

  cat >"${WATCHDOG_DIR}/watchdog.service" <<EOF
[Unit]
Description=AaaS Hermes watchdog
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONFIG_FILE}
ExecStart=${WATCHDOG_DIR}/watchdog.sh
Restart=always
RestartSec=20
WorkingDirectory=${ROOT_DIR}

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
    warn "Could not find the installed Hermes gateway systemd unit. HERMES_HOME may need a manual service override."
    return
  fi

  dropin_dir="/etc/systemd/system/${unit_name}.d"
  dropin_file="${dropin_dir}/aaas.conf"

  run $SUDO mkdir -p "$dropin_dir"
  printf "[Service]\nEnvironment=HERMES_HOME=%s\nEnvironmentFile=%s\n" "$HERMES_HOME" "$CONFIG_FILE" | $SUDO tee "$dropin_file" >/dev/null
  run $SUDO systemctl daemon-reload
  ok "Hermes gateway service ${unit_name} is pinned to ${HERMES_HOME}."
}

verify_hermes_runtime() {
  step "Verifying Hermes gateway"

  [[ -f "$CONFIG_FILE" ]] || fail "Hermes config is missing: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  have hermes || fail "Hermes executable is not on PATH. Fix Hermes install, then rerun install.sh."
  hermes --help 2>/dev/null | grep -qi gateway || fail "Hermes gateway command is unavailable. Reinstall Hermes Agent, then rerun install.sh."
  ok "Hermes gateway command is available."

  if [[ -f "${HERMES_HOME}/config.yaml" ]]; then
    ok "Hermes config.yaml is present at ${HERMES_HOME}."
  else
    warn "Hermes config.yaml not found yet at ${HERMES_HOME}/config.yaml — expected, since --skip-setup was used."
    warn "It will be created on first run: env HERMES_HOME=${HERMES_HOME} hermes doctor"
  fi

  if have systemctl; then
    [[ -n "$SUDO" || "${EUID:-$(id -u)}" -eq 0 ]] || fail "Installing the Hermes gateway system service requires root or sudo."
    [[ -n "$HERMES_BIN" ]] || fail "HERMES_BIN is not set. ensure_hermes_symlink must run before verify_hermes_runtime."
    run $SUDO env HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" gateway install --system
    configure_hermes_gateway_service_env
    run $SUDO env HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" gateway start --system

    if ! $SUDO env HERMES_HOME="$HERMES_HOME" "$HERMES_BIN" gateway status --system >/dev/null 2>&1; then
      write_alert "Hermes gateway system service failed verification"
      fail "Hermes gateway system service is not running. Check: sudo env HERMES_HOME=${HERMES_HOME} ${HERMES_BIN} gateway status --system"
    fi
    ok "Hermes gateway system service is running."
  else
    if ! start_background_service "hermes.*gateway" env HERMES_HOME="$HERMES_HOME" hermes gateway; then
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

  ok "Watchdog service enabled: ${unit_name}. Not started — start it manually when ready:"
  ok "  sudo systemctl start ${unit_name}"
}

summary() {
  printf "\n%s%sInstallation complete.%s\n" "${GREEN}${BOLD}" "✨ " "${RESET}"
  printf "%sHermes home:%s %s\n" "${BOLD}" "${RESET}" "$HERMES_HOME"
  printf "%sConfig:%s      %s\n" "${BOLD}" "${RESET}" "$CONFIG_FILE"
  printf "%sWatchdog:%s    %s\n" "${BOLD}" "${RESET}" "${WATCHDOG_DIR}/watchdog.sh"
  if have systemctl && systemctl is-active --quiet aaas-watchdog.service 2>/dev/null; then
    printf "%sService:%s     %s\n" "${BOLD}" "${RESET}" "aaas-watchdog.service active"
  elif have systemctl && systemctl is-enabled --quiet aaas-watchdog.service 2>/dev/null; then
    printf "%sService:%s     %s\n" "${BOLD}" "${RESET}" "aaas-watchdog.service enabled, not started (sudo systemctl start aaas-watchdog.service)"
  fi
}

main() {
  banner
  ensure_base_tools
  sync_platform_files
  ensure_node
  ensure_opencode
  ensure_python_yaml
  ensure_docker
  install_hermes
  write_watchdog
  verify_hermes_runtime
  install_watchdog_service
  summary
}

main "$@"