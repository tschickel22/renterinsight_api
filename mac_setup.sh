#!/usr/bin/env bash
#
# mac_setup.sh — bootstrap a fresh Mac for DMS, Renter Insight, and the
# Marketing site. Idempotent: safe to re-run.

set -u
set -o pipefail

# ---- config ----------------------------------------------------------------

SRC_DIR="${HOME}/src"
SECRETS_DIR="${HOME}/Library/Mobile Documents/com~apple~CloudDocs/platform-secrets"

RUBY_VERSION="${RUBY_VERSION:-3.2.2}"
NODE_VERSION="${NODE_VERSION:-20}"

# name | git url | type (rails-docker | node) | env-file-in-secrets | branch (empty = default)
PROJECTS=(
  "renterinsight_api|git@github.com:tschickel22/renterinsight_api.git|rails-docker|dms.env|staging"
  "renter-insight-app|git@github.com:doughays/renter-insight-app.git|rails-docker|renter-insight.env|feature-rubs"
  "Platform_DMS_8.4.25|git@github.com:tschickel22/Platform_DMS_8.4.25.git|node|dms-frontend.env|staging"
  "Renter-Insight-Marketing-Site1.1|git@github.com:tschickel22/Renter-Insight-Marketing-Site1.1.git|node|marketing.env|"
)

# ---- logging ---------------------------------------------------------------

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
FAILURES=()

step()  { printf "\n${BOLD}${BLUE}==> %s${RESET}\n" "$*"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}!${RESET} %s\n" "$*"; }
fail()  { printf "${RED}✗${RESET} %s\n" "$*"; FAILURES+=("$*"); }

run() {
  # run "<label>" cmd args...
  local label="$1"; shift
  if "$@"; then ok "$label"; else fail "$label"; return 1; fi
}

# ---- preflight -------------------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf "${RED}This script is for macOS only.${RESET}\n" >&2
  exit 1
fi

step "Ensuring Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode CLT already installed"
else
  warn "Triggering Xcode CLT install — complete the GUI prompt, then re-run this script."
  xcode-select --install || true
  exit 1
fi

# ---- Homebrew --------------------------------------------------------------

step "Installing Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew already installed ($(brew --version | head -n1))"
else
  if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    ok "Homebrew installed"
  else
    fail "Homebrew install failed"; exit 1
  fi
fi

# Put brew on PATH for both Apple Silicon and Intel for the rest of this run.
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

brew_install() {
  local pkg="$1" cask="${2:-}"
  if [[ -n "$cask" ]]; then
    if brew list --cask "$pkg" >/dev/null 2>&1; then
      ok "$pkg (cask) already installed"
    else
      run "install cask $pkg" brew install --cask "$pkg"
    fi
  else
    if brew list "$pkg" >/dev/null 2>&1; then
      ok "$pkg already installed"
    else
      run "install $pkg" brew install "$pkg"
    fi
  fi
}

step "Installing core CLI tools (git, gh, rbenv, ruby-build, nvm)"
brew_install git
brew_install gh
brew_install rbenv
brew_install ruby-build
brew_install nvm

step "Installing Docker Desktop"
brew_install docker cask

# ---- shell init snippet ----------------------------------------------------

SHELL_RC="${HOME}/.zshrc"
[[ "${SHELL:-}" == *"/bash" ]] && SHELL_RC="${HOME}/.bash_profile"

ensure_line() {
  local line="$1" file="$2"
  [[ -f "$file" ]] || : > "$file"
  grep -qxF "$line" "$file" || printf "%s\n" "$line" >> "$file"
}

step "Configuring shell (${SHELL_RC})"
ensure_line 'eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"' "$SHELL_RC"
ensure_line 'eval "$(rbenv init - zsh)"' "$SHELL_RC"
ensure_line 'export NVM_DIR="$HOME/.nvm"' "$SHELL_RC"
ensure_line '[ -s "$(brew --prefix nvm)/nvm.sh" ] && . "$(brew --prefix nvm)/nvm.sh"' "$SHELL_RC"
ok "Shell init written"

# Load into the current shell so subsequent steps work.
eval "$(rbenv init - bash)" 2>/dev/null || true
export NVM_DIR="$HOME/.nvm"
mkdir -p "$NVM_DIR"
# shellcheck disable=SC1091
[ -s "$(brew --prefix nvm)/nvm.sh" ] && . "$(brew --prefix nvm)/nvm.sh"

# ---- Ruby ------------------------------------------------------------------

step "Installing Ruby ${RUBY_VERSION} via rbenv"
if rbenv versions --bare | grep -qx "$RUBY_VERSION"; then
  ok "Ruby ${RUBY_VERSION} already installed"
else
  run "rbenv install ${RUBY_VERSION}" rbenv install "$RUBY_VERSION"
fi
run "rbenv global ${RUBY_VERSION}" rbenv global "$RUBY_VERSION"
run "install bundler" gem install bundler --no-document

# ---- Node ------------------------------------------------------------------

step "Installing Node ${NODE_VERSION} via nvm"
if command -v nvm >/dev/null 2>&1; then
  if nvm install "$NODE_VERSION" && nvm alias default "$NODE_VERSION" && nvm use default >/dev/null; then
    ok "Node $(node -v) active"
  else
    fail "nvm install ${NODE_VERSION}"
  fi
else
  fail "nvm not loaded — restart your shell and re-run"
fi

# ---- GitHub auth -----------------------------------------------------------

step "Checking GitHub auth"
if gh auth status >/dev/null 2>&1; then
  ok "gh already authenticated"
else
  warn "Run 'gh auth login' after setup completes (SSH cloning will still work if your key is registered)."
fi

# ---- iCloud secrets sanity check ------------------------------------------

step "Checking iCloud secrets directory"
if [[ -d "$SECRETS_DIR" ]]; then
  ok "Found $SECRETS_DIR"
else
  fail "Secrets directory not found at $SECRETS_DIR — .env copies will be skipped per project"
fi

# ---- clone + per-project setup --------------------------------------------

mkdir -p "$SRC_DIR"

copy_env() {
  local project_dir="$1" env_file="$2"
  local src="${SECRETS_DIR}/${env_file}"
  local dst="${project_dir}/.env"
  if [[ ! -d "$SECRETS_DIR" ]]; then
    warn "skip env copy for $(basename "$project_dir"): secrets dir missing"
    return 0
  fi
  if [[ ! -f "$src" ]]; then
    fail "env file missing: $src"
    return 1
  fi
  if cp "$src" "$dst"; then
    ok "copied ${env_file} → $(basename "$project_dir")/.env"
  else
    fail "copy ${env_file} → $dst"
  fi
}

setup_project() {
  local name="$1" url="$2" type="$3" env_file="$4" branch="$5"
  local dir="${SRC_DIR}/${name}"

  step "Project: ${name}${branch:+ (branch: $branch)}"

  if [[ -d "$dir/.git" ]]; then
    ok "repo already cloned at $dir"
    if [[ -n "$branch" ]]; then
      ( cd "$dir" && run "checkout $branch ($name)" git checkout "$branch" )
    fi
  else
    if [[ -n "$branch" ]]; then
      run "clone $name ($branch)" git clone -b "$branch" "$url" "$dir" || return 1
    else
      run "clone $name" git clone "$url" "$dir" || return 1
    fi
  fi

  copy_env "$dir" "$env_file"

  # Project-specific pre-start steps
  if [[ "$name" == "renter-insight-app" ]]; then
    if command -v docker >/dev/null 2>&1; then
      run "docker volume create renter-volume" docker volume create renter-volume
    else
      warn "docker not on PATH yet — after Docker Desktop first-run, manually run: docker volume create renter-volume"
    fi
  fi

  case "$type" in
    rails-docker)
      ( cd "$dir" && run "bundle install ($name)" bundle install )
      if [[ -f "$dir/package.json" ]]; then
        ( cd "$dir" && run "npm install ($name)" npm install )
      fi
      if [[ -f "$dir/docker-compose.yml" || -f "$dir/compose.yml" ]]; then
        warn "$name has docker-compose — start with: (cd $dir && docker compose up)"
      fi
      ;;
    node)
      ( cd "$dir" && run "npm install ($name)" npm install )
      ;;
    *)
      fail "unknown project type: $type"
      ;;
  esac
}

for entry in "${PROJECTS[@]}"; do
  IFS='|' read -r name url type env_file branch <<< "$entry"
  setup_project "$name" "$url" "$type" "$env_file" "$branch" || true
done

# ---- summary ---------------------------------------------------------------

print_manual_steps() {
  printf "\n${BOLD}Manual steps (not automated):${RESET}\n"
  printf "  • Renter Insight: restore the database dump into the \`renter-volume\` Postgres volume\n"
  printf "    after \`docker compose up\` — this is a manual step and is not handled by this script.\n"
}

printf "\n${BOLD}==== Setup summary ====${RESET}\n"
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  printf "${GREEN}All steps completed successfully.${RESET}\n"
  printf "Next:\n"
  printf "  1. Open Docker Desktop once to finish its first-run setup.\n"
  printf "  2. Restart your shell (or: source %s).\n" "$SHELL_RC"
  printf "  3. cd ~/src/<project> and start the app.\n"
  print_manual_steps
  exit 0
else
  printf "${RED}${#FAILURES[@]} step(s) failed:${RESET}\n"
  for f in "${FAILURES[@]}"; do printf "  ${RED}•${RESET} %s\n" "$f"; done
  print_manual_steps
  exit 1
fi
