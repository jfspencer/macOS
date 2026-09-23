#!/usr/bin/env bash
#
# System Setup Script (macOS)
# Configures a fresh Apple Silicon macOS installation with common development tools
#
# Prerequisites:
#   - Apple Silicon Mac (Intel Macs are not supported)
#   - Xcode 26 or later, with its developer tools selected
#     (sudo xcode-select -s /Applications/Xcode.app)
#
# Usage: ./system-setup.sh [OPTIONS]
#   --skip-apps               Skip GUI applications (Homebrew casks)
#   --skip-desktop-settings   Skip macOS desktop customization (dark mode, dock)
#   --skip-gitturtle          Skip building GitTurtle from source
#   --dry-run                 Show what would be installed without making changes
#   --help                    Show this help message
#
# Ported from the Ubuntu setup script (https://github.com/jfspencer/linux).
# Linux-only pieces -- System76/NVIDIA drivers, signed apt repos, Flatpak,
# GNOME apps and settings, Docker Engine, NodeSource -- are intentionally
# dropped. Homebrew covers everything that exists on macOS.
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"

# Homebrew lives here on Apple Silicon, the only supported architecture.
# It is resolved again after Homebrew is ensured, so this stays a sane default.
HOMEBREW_PREFIX="/opt/homebrew"

# Feature flags (can be overridden via command line)
INSTALL_APPS=true
INSTALL_DESKTOP_SETTINGS=true
INSTALL_GITTURTLE=true
DRY_RUN=false

# Configurable versions and values
readonly REQUIRED_XCODE_MAJOR=26
# What to hand to `n`: "lts", "latest", or an exact version like "24.19.0".
readonly TARGET_NODE_CHANNEL="lts"
# `n` installs the active Node runtime under N_PREFIX. A per-user prefix avoids
# sudo and keeps n's node from fighting Homebrew's node for PATH precedence.
readonly NODE_PREFIX="${HOME}/.n"
# Tracks the current PostgreSQL release; swap for another postgresql@NN if needed.
readonly POSTGRES_FORMULA="postgresql@18"
readonly TWINGATE_NETWORK="angelstudios"
readonly GITTURTLE_REPO="https://github.com/FernandoX7/GitTurtle.git"
readonly DEVELOPER_DIR="${HOME}/Developer"
readonly GITTURTLE_SRC_DIR="${DEVELOPER_DIR}/GitTurtle"
readonly GITTURTLE_APP="/Applications/GitTurtle.app"

# =============================================================================
# Application Lists (edit these to customize your installation)
# =============================================================================

# Homebrew casks (GUI applications): "cask|Display Name"
#
# These are the macOS counterparts of the Linux script's signed-repo and
# Flatpak apps. GNOME-only apps (Pika Backup, Binary, Collision, Constrict,
# Curtail, Dialect, Emblem, Errands, Eyedropper, Iotas, Graphs, Die Bahn,
# Solanum, Converter, Valuta, Video Trimmer, Wordbook, Warp) have no macOS
# equivalent and were dropped in the port.
readonly CASK_APPS=(
    # Browsers
    "brave-browser|Brave Browser"
    "google-chrome|Google Chrome"
    "chromium|Chromium Browser"
    # Development
    "jetbrains-toolbox|JetBrains Toolbox"
    "pgadmin4|pgAdmin 4"
    "ngrok|ngrok"
    # Media & productivity
    "vlc|VLC Media Player"
    "libreoffice|LibreOffice"
    "spotify|Spotify"
    "proton-mail|Proton Mail"
    "slack|Slack"
    "zoom|Zoom"
    "drawio|draw.io"
    "steam|Steam"
    "gimp|GIMP Image Editor"
)

# Homebrew formulae with no post-install steps: "formula|Display Name"
readonly SIMPLE_FORMULAE=(
    "ffmpeg|FFmpeg"
    "go|Go Programming Language"
    "magic-wormhole|Magic Wormhole"
    "gh|GitHub CLI"
    "pnpm|pnpm"
)

# NPM global packages (installed with the `n`-managed Node runtime)
readonly NPM_PACKAGES=(
    "@webos-tools/cli"
)

# =============================================================================
# Logging & Output
# =============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly NC='\033[0m'

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
}

print_status() {
    echo -e "${BLUE}[*]${NC} $1"
    log "INFO" "$1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    log "SUCCESS" "$1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
    log "WARNING" "$1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
    log "ERROR" "$1"
}

print_skip() {
    echo -e "${GRAY}[−]${NC} $1 ${GRAY}(already installed)${NC}"
    log "SKIP" "$1"
}

print_dry_run() {
    echo -e "${CYAN}[DRY]${NC} Would: $1"
    log "DRY_RUN" "$1"
}

print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log "SECTION" "$1"
}

# =============================================================================
# Error Handling
# =============================================================================

SUDO_KEEPALIVE_PID=""

cleanup() {
    local exit_code=$?
    # Kill sudo keepalive background process
    if [[ -n "${SUDO_KEEPALIVE_PID}" ]]; then
        kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
        wait "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    fi
    if [[ ${exit_code} -ne 0 ]]; then
        print_error "Script failed with exit code ${exit_code}"
        print_error "Check log file for details: ${LOG_FILE}"
    fi
    cd "${SCRIPT_DIR}" 2>/dev/null || true
}

trap cleanup EXIT

handle_error() {
    local line_number="$1"
    local command="$2"
    local exit_code="$3"
    print_error "Command failed at line ${line_number}: ${command} (exit code: ${exit_code})"
}

trap 'handle_error ${LINENO} "${BASH_COMMAND}" $?' ERR

# =============================================================================
# Detection & Check Functions
# =============================================================================

command_exists() {
    command -v "$1" &>/dev/null
}

formula_installed() {
    command_exists brew || return 1
    brew list --formula "$1" &>/dev/null
}

cask_installed() {
    command_exists brew || return 1
    brew list --cask "$1" &>/dev/null
}

# =============================================================================
# Package Management Functions (Idempotent)
# =============================================================================

# Single funnel for brew. Output streams to the terminal and the log at the
# same time, so a slow download (lines still arriving) looks different from a
# hang (no lines at all). pipefail (set at the top of the script) keeps brew's
# exit status, not tee's.
brew_run() {
    brew "$@" 2>&1 | tee -a "${LOG_FILE}"
}

brew_update() {
    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "brew update"
        return 0
    fi
    print_status "Updating Homebrew formulae and casks..."
    if brew_run update; then
        print_success "Homebrew updated"
    else
        local exit_code=$?
        print_error "brew update failed (exit code ${exit_code}); output is above and in ${LOG_FILE}"
        return ${exit_code}
    fi
}

brew_install_formula() {
    local pkg="$1"
    local name="${2:-${1}}"

    if formula_installed "${pkg}"; then
        print_skip "${name}"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "brew install ${pkg}"
        return 0
    fi

    print_status "Installing ${name}..."
    if brew_run install "${pkg}"; then
        print_success "${name} installed"
    else
        local exit_code=$?
        print_error "brew install failed for ${pkg} (exit code ${exit_code}); output is above and in ${LOG_FILE}"
        return ${exit_code}
    fi
}

brew_install_cask() {
    local cask="$1"
    local name="${2:-${1}}"

    if cask_installed "${cask}"; then
        print_skip "${name}"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "brew install --cask ${cask}"
        return 0
    fi

    print_status "Installing ${name}..."
    if brew_run install --cask "${cask}"; then
        print_success "${name} installed"
    else
        local exit_code=$?
        print_error "brew install --cask failed for ${cask} (exit code ${exit_code}); output is above and in ${LOG_FILE}"
        return ${exit_code}
    fi
}

start_brew_service() {
    local formula="$1"

    if command_exists brew && brew services list 2>/dev/null | awk 'NR > 1 {print $1, $2}' | grep -qx "${formula} started"; then
        print_skip "${formula} service (already running)"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "brew services start ${formula}"
        return 0
    fi

    print_status "Starting ${formula} service..."
    if brew_run services start "${formula}"; then
        print_success "${formula} service started (launches at login)"
    else
        local exit_code=$?
        print_error "brew services start failed for ${formula} (exit code ${exit_code})"
        return ${exit_code}
    fi
}

# Idempotently appends a block of lines to a shell profile when MARKER is not
# already present. Used for every PATH/JAVA_HOME addition in this script.
add_profile_block() {
    local file="$1"
    local marker="$2"
    shift 2

    if grep -qF "${marker}" "${file}" 2>/dev/null; then
        print_skip "PATH entry (${marker})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Add '${marker}' block to ${file}"
        return 0
    fi

    print_status "Adding '${marker}' to ${file}..."
    {
        echo ""
        local line
        for line in "$@"; do
            echo "${line}"
        done
    } >> "${file}"
    print_success "Added '${marker}' to ${file}"
}

# =============================================================================
# Preflight Checks
# =============================================================================

check_platform() {
    print_section "Preflight Checks"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        print_error "This script is for macOS only"
        exit 1
    fi

    if [[ "$(uname -m)" != "arm64" ]]; then
        print_error "Intel Macs are not supported by this script (Apple Silicon required)"
        exit 1
    fi
    print_success "Apple Silicon (arm64) detected"

    check_xcode
}

check_xcode() {
    local developer_dir=""
    if ! developer_dir="$(xcode-select -p 2>/dev/null)"; then
        print_error "Xcode command-line developer tools not found."
        print_error "Install Xcode ${REQUIRED_XCODE_MAJOR}+, then run: sudo xcode-select -s /Applications/Xcode.app"
        exit 1
    fi

    if [[ "${developer_dir}" == *"CommandLineTools"* ]]; then
        print_error "Only the standalone Command Line Tools are selected, but full Xcode ${REQUIRED_XCODE_MAJOR}+ is required."
        print_error "Install Xcode ${REQUIRED_XCODE_MAJOR}+, then run: sudo xcode-select -s /Applications/Xcode.app"
        exit 1
    fi

    if ! command_exists xcodebuild; then
        print_error "xcodebuild not found; install full Xcode ${REQUIRED_XCODE_MAJOR}+ before running this script"
        exit 1
    fi

    local xcode_version major
    xcode_version="$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}')"
    major="${xcode_version%%.*}"

    if [[ -z "${major}" || "${major}" -lt "${REQUIRED_XCODE_MAJOR}" ]]; then
        print_error "Xcode ${REQUIRED_XCODE_MAJOR}+ required (found ${xcode_version:-none})"
        exit 1
    fi

    print_success "Xcode ${xcode_version} with developer tools detected"
}

ensure_homebrew() {
    print_section "Homebrew"

    if command_exists brew; then
        print_skip "Homebrew"
    elif [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Homebrew via the official installer"
    else
        print_status "Installing Homebrew..."
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        print_success "Homebrew installed"
    fi

    if [[ "${DRY_RUN}" != true ]]; then
        HOMEBREW_PREFIX="$("${HOMEBREW_PREFIX}/bin/brew" --prefix)"
        eval "$("${HOMEBREW_PREFIX}/bin/brew" shellenv)"
        # brew update is run explicitly in the Package Lists section; stop each
        # install from triggering its own auto-update on top of that.
        export HOMEBREW_NO_AUTO_UPDATE=1

        add_profile_block "${HOME}/.zprofile" "${HOMEBREW_PREFIX}/bin/brew shellenv" \
            "eval \"\$(${HOMEBREW_PREFIX}/bin/brew shellenv)\""
    fi
}

# =============================================================================
# Installation Functions
# =============================================================================

install_git() {
    print_section "Git"

    brew_install_formula git "Git"

    if command_exists git; then
        print_success "Git $(git --version | awk '{print $3}') available"
    fi
}

install_git_lfs() {
    print_section "Git LFS"

    brew_install_formula git-lfs "Git LFS"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "git lfs install"
        return 0
    fi

    if command_exists git-lfs; then
        print_status "Configuring Git LFS for user..."
        git lfs install 2>&1 | tee -a "${LOG_FILE}"
        print_success "Git LFS configured"
    else
        print_warning "Git LFS command not available after installation"
    fi
}

# `n` is bootstrapped from Homebrew's node/npm, then owns the active runtime.
# This is the macOS equivalent of the Linux script's NodeSource + n flow.
# `n` defaults to /usr/local (which needs sudo and loses PATH precedence to
# Homebrew), so N_PREFIX points at ~/.n instead and .zshrc puts it first.
resolve_node_target() {
    case "${TARGET_NODE_CHANNEL}" in
        lts)    n --lts 2>/dev/null ;;
        latest) n --latest 2>/dev/null ;;
        *)      echo "${TARGET_NODE_CHANNEL}" ;;
    esac
}

install_nodejs() {
    print_section "Node.js & npm"

    brew_install_formula node "Node.js (bootstrap for n)"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "npm install -g n"
        print_dry_run "n ${TARGET_NODE_CHANNEL}"
        print_dry_run "Add N_PREFIX (${NODE_PREFIX}) to PATH in .zshrc"
        return 0
    fi

    add_profile_block "${HOME}/.zshrc" "${NODE_PREFIX}/bin" \
        "# Node.js (n)" \
        "export N_PREFIX=\"${NODE_PREFIX}\"" \
        'export PATH="${N_PREFIX}/bin:${PATH}"'
    export N_PREFIX="${NODE_PREFIX}"
    export PATH="${NODE_PREFIX}/bin:${PATH}"

    if ! command_exists n; then
        print_status "Installing 'n' Node version manager..."
        npm install -g n 2>&1 | tee -a "${LOG_FILE}"
        hash -r
        print_success "'n' installed"
    else
        print_skip "'n' Node version manager"
    fi

    local target_version current_version=""
    target_version="$(resolve_node_target)"
    if command_exists node; then
        current_version="$(node --version | sed 's/^v//')"
    fi

    if [[ -n "${target_version}" && "${current_version}" == "${target_version}" ]]; then
        print_skip "Node.js v${current_version} (${TARGET_NODE_CHANNEL})"
    else
        print_status "Installing Node.js (${TARGET_NODE_CHANNEL}${target_version:+ -> ${target_version}}) using 'n'..."
        n "${TARGET_NODE_CHANNEL}" 2>&1 | tee -a "${LOG_FILE}"
        hash -r
    fi

    local active_version active_path
    active_version="$(node --version | sed 's/^v//')"
    active_path="$(command -v node)"
    print_success "Active Node.js version: v${active_version}"

    if [[ "${active_path}" != "${NODE_PREFIX}/bin/node" ]]; then
        print_warning "node resolves to ${active_path}; expected ${NODE_PREFIX}/bin/node (new shells pick this up from ~/.zshrc)"
    fi
}

install_npm_packages() {
    print_section "NPM Global Packages"

    if ! command_exists npm; then
        print_warning "npm not available, skipping npm packages"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "npm install -g ${NPM_PACKAGES[*]}"
        return 0
    fi

    local installed_count=0
    local skipped_count=0

    for package in "${NPM_PACKAGES[@]}"; do
        if npm list -g "${package}" &>/dev/null; then
            print_skip "${package}"
            skipped_count=$((skipped_count + 1))
        else
            print_status "Installing npm package: ${package}..."
            if npm install -g "${package}" 2>&1 | tee -a "${LOG_FILE}"; then
                print_success "${package} installed"
                installed_count=$((installed_count + 1))
            else
                print_warning "Failed to install ${package}"
            fi
        fi
    done

    echo ""
    if [[ ${installed_count} -gt 0 ]]; then
        print_success "Newly installed: ${installed_count} packages"
    fi
    if [[ ${skipped_count} -gt 0 ]]; then
        print_status "Already installed: ${skipped_count} packages"
    fi
}

install_bun() {
    print_section "Bun Runtime"

    brew_install_formula bun "Bun"

    if command_exists bun; then
        print_success "Bun $(bun --version) installed"
    else
        print_warning "Bun installed but not found in PATH (may need to restart shell)"
    fi
}

# Homebrew's rustup is keg-only, so its bin directory is added to PATH before
# rustup is used. The formula no longer ships rustup-init; toolchains are
# installed with `rustup toolchain install`.
install_rust() {
    print_section "Rust Toolchain"

    brew_install_formula rustup "rustup (Rust toolchain manager)"
    export PATH="${HOMEBREW_PREFIX}/opt/rustup/bin:${PATH}"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "rustup toolchain install stable --profile default"
        print_dry_run "rustup component add rustfmt clippy"
        print_dry_run "Add rustup and Cargo to PATH in .zshrc"
        return 0
    fi

    if rustup toolchain list 2>/dev/null | grep -qE '^stable'; then
        print_status "Updating Rust stable toolchain..."
        rustup update stable 2>&1 | tee -a "${LOG_FILE}"
    else
        print_status "Installing Rust stable toolchain..."
        rustup toolchain install stable --profile default 2>&1 | tee -a "${LOG_FILE}"
    fi
    rustup default stable 2>&1 | tee -a "${LOG_FILE}"

    print_status "Ensuring rustfmt and clippy are installed..."
    rustup component add rustfmt clippy 2>&1 | tee -a "${LOG_FILE}" || \
        print_warning "Could not add rustfmt/clippy components"

    local rustup_bin="${HOMEBREW_PREFIX}/opt/rustup/bin"
    add_profile_block "${HOME}/.zshrc" "${rustup_bin}" \
        "# Rust (rustup + cargo)" \
        "export PATH=\"${rustup_bin}:\${HOME}/.cargo/bin:\${PATH}\""
    export PATH="${HOME}/.cargo/bin:${PATH}"

    if command_exists rustc && command_exists cargo; then
        print_success "Rust $(rustc --version | awk '{print $2}') / Cargo $(cargo --version | awk '{print $2}') installed successfully"
    else
        print_warning "Rust installed but rustc/cargo not found in PATH (may need to restart shell)"
    fi
}

install_jdk() {
    print_section "Java Development Kit (OpenJDK)"

    # Note: /usr/bin/java is a macOS stub that exists even without a JDK, so
    # check Homebrew and the system symlink instead of `command_exists java`.
    # `openjdk` tracks the newest release; use openjdk@21 if an LTS is wanted.
    brew_install_formula openjdk "OpenJDK"

    local jdk_link="/Library/Java/JavaVirtualMachines/openjdk.jdk"
    if [[ -L "${jdk_link}" ]]; then
        print_skip "JDK system symlink"
    elif [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Symlink ${HOMEBREW_PREFIX}/opt/openjdk/libexec/openjdk.jdk to ${jdk_link}"
    else
        print_status "Linking OpenJDK into /Library/Java/JavaVirtualMachines..."
        sudo mkdir -p /Library/Java/JavaVirtualMachines
        sudo ln -sfn "${HOMEBREW_PREFIX}/opt/openjdk/libexec/openjdk.jdk" "${jdk_link}"
        print_success "OpenJDK linked for system Java wrappers"
    fi

    add_profile_block "${HOME}/.zshrc" "JAVA_HOME" \
        "# Java (OpenJDK)" \
        "export JAVA_HOME=\"${HOMEBREW_PREFIX}/opt/openjdk\"" \
        'export PATH="${JAVA_HOME}/bin:${PATH}"'
    export JAVA_HOME="${HOMEBREW_PREFIX}/opt/openjdk"
    export PATH="${JAVA_HOME}/bin:${PATH}"

    if command_exists javac; then
        print_success "JDK installed (Java $(javac -version 2>&1 | awk '{print $2}'))"
    else
        print_warning "OpenJDK installed but javac not found in PATH (may need to restart shell)"
    fi
}

# GitTurtle has no published releases, so it is cloned into ~/Developer, built
# from source with Xcode's toolchain and installed to /Applications. Xcode 26+
# (checked in preflight) plus Git and Rust are required first.
# See https://github.com/FernandoX7/GitTurtle/blob/main/README.md
install_gitturtle() {
    print_section "GitTurtle (build from source)"

    if [[ "${INSTALL_GITTURTLE}" != true ]]; then
        print_warning "Skipping GitTurtle (disabled)"
        return 0
    fi

    if [[ -d "${GITTURTLE_APP}" ]]; then
        local installed_version
        installed_version="$(plutil -extract CFBundleShortVersionString raw -o - "${GITTURTLE_APP}/Contents/Info.plist" 2>/dev/null || echo "unknown")"
        print_skip "GitTurtle (${installed_version})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Ensure the Xcode Metal toolchain is available"
        print_dry_run "Clone ${GITTURTLE_REPO} to ${GITTURTLE_SRC_DIR}"
        print_dry_run "Build with scripts/package-macos.sh and install to ${GITTURTLE_APP}"
        return 0
    fi

    # Prerequisites: both functions are idempotent, so this is a no-op when
    # main() has already run them.
    if ! command_exists git; then
        install_git
    fi
    if ! command_exists rustup && [[ ! -x "${HOMEBREW_PREFIX}/opt/rustup/bin/rustup" ]]; then
        install_rust
    fi
    export PATH="${HOMEBREW_PREFIX}/opt/rustup/bin:${HOME}/.cargo/bin:${PATH}"
    if [[ -f "${HOME}/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.cargo/env"
    fi

    if ! command_exists cargo; then
        print_error "Cargo is required to build GitTurtle, skipping"
        return 0
    fi

    # Xcode 26 ships the Metal toolchain as a separate downloadable component
    if xcrun -f metal &>/dev/null; then
        print_skip "Metal toolchain"
    else
        print_status "Downloading the Xcode Metal toolchain (required by GitTurtle)..."
        if ! xcodebuild -downloadComponent MetalToolchain 2>&1 | tee -a "${LOG_FILE}"; then
            print_warning "Could not download the Metal toolchain; install it via Xcode > Settings > Components, then re-run"
            return 0
        fi
    fi

    if [[ ! -d "${DEVELOPER_DIR}" ]]; then
        print_status "Creating ${DEVELOPER_DIR}..."
        mkdir -p "${DEVELOPER_DIR}"
    fi

    if [[ -d "${GITTURTLE_SRC_DIR}/.git" ]]; then
        print_status "Updating GitTurtle clone in ${GITTURTLE_SRC_DIR}..."
        git -C "${GITTURTLE_SRC_DIR}" pull --ff-only 2>&1 | tee -a "${LOG_FILE}"
    elif [[ -e "${GITTURTLE_SRC_DIR}" ]]; then
        print_error "${GITTURTLE_SRC_DIR} exists but is not a git clone, skipping GitTurtle"
        return 0
    else
        print_status "Cloning GitTurtle to ${GITTURTLE_SRC_DIR}..."
        git clone "${GITTURTLE_REPO}" "${GITTURTLE_SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}"
    fi

    print_status "Building GitTurtle (this can take a while)..."
    (cd "${GITTURTLE_SRC_DIR}" && ./scripts/package-macos.sh) 2>&1 | tee -a "${LOG_FILE}"

    local built_app="${GITTURTLE_SRC_DIR}/dist/GitTurtle.app"
    if [[ ! -d "${built_app}" ]]; then
        print_warning "GitTurtle build finished but ${built_app} was not found"
        return 0
    fi

    print_status "Installing GitTurtle to /Applications..."
    rm -rf "${GITTURTLE_APP}"
    cp -R "${built_app}" "/Applications/"
    print_success "GitTurtle installed (open it from Applications)"
}

install_claude_code() {
    print_section "Claude Code CLI"

    if cask_installed claude-code; then
        local claude_version="unknown"
        if command_exists claude; then
            claude_version="$(claude --version 2>/dev/null || echo "unknown")"
        fi
        print_skip "Claude Code CLI (${claude_version})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Remove any npm-installed Claude Code"
        print_dry_run "brew install --cask claude-code"
        return 0
    fi

    if command_exists npm && npm list -g @anthropic-ai/claude-code &>/dev/null; then
        print_warning "Found an npm-installed Claude Code; removing it in favour of the Homebrew cask"
        npm uninstall -g @anthropic-ai/claude-code 2>&1 | tee -a "${LOG_FILE}" || true
    fi

    brew_install_cask claude-code "Claude Code CLI"

    if command_exists claude; then
        local claude_version
        claude_version="$(claude --version 2>/dev/null || echo "unknown")"
        print_success "Claude Code CLI ${claude_version} installed successfully"
    else
        print_warning "Claude Code installed but not found in PATH (may need to restart shell)"
    fi
}

install_opencode() {
    print_section "OpenCode CLI"

    local opencode_bin_dir="${HOME}/.opencode/bin"
    local opencode_path="${opencode_bin_dir}/opencode"

    if command_exists opencode || [[ -x "${opencode_path}" ]]; then
        local opencode_bin="opencode"
        command_exists opencode || opencode_bin="${opencode_path}"
        local opencode_version
        opencode_version="$("${opencode_bin}" --version 2>/dev/null || echo "unknown")"
        print_skip "OpenCode CLI (${opencode_version})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install OpenCode CLI via official installer (curl -fsSL https://opencode.ai/v2/install | bash)"
        print_dry_run "Add ~/.opencode/bin to PATH in .zshrc"
        return 0
    fi

    # Homebrew's `opencode` formula still tracks the v1 line, so the official
    # v2 installer is used instead (same installer as the Linux script).
    print_status "Installing OpenCode CLI..."
    local tmp_installer
    tmp_installer="$(mktemp)"
    curl -fsSL -o "${tmp_installer}" https://opencode.ai/v2/install
    bash "${tmp_installer}"
    rm -f "${tmp_installer}"
    print_success "OpenCode CLI installed"

    add_profile_block "${HOME}/.zshrc" ".opencode/bin" \
        "# OpenCode" \
        'export PATH="${HOME}/.opencode/bin:${PATH}"'
    export PATH="${opencode_bin_dir}:${PATH}"

    if command_exists opencode; then
        local opencode_version
        opencode_version="$(opencode --version 2>/dev/null || echo "unknown")"
        print_success "OpenCode CLI ${opencode_version} installed successfully"
    else
        print_warning "OpenCode installed but not found in PATH (may need to restart shell)"
    fi
}

install_codex() {
    print_section "Codex CLI"

    if cask_installed codex; then
        local codex_version="unknown"
        if command_exists codex; then
            codex_version="$(codex --version 2>/dev/null || echo "unknown")"
        fi
        print_skip "Codex CLI (${codex_version})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "brew install --cask codex"
        return 0
    fi

    brew_install_cask codex "Codex CLI"

    if command_exists codex; then
        local codex_version
        codex_version="$(codex --version 2>/dev/null || echo "unknown")"
        print_success "Codex CLI ${codex_version} installed successfully"
    else
        print_warning "Codex installed but not found in PATH (may need to restart shell)"
    fi
}

install_1password() {
    print_section "1Password"

    if cask_installed 1password; then
        print_skip "1Password"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "brew install --cask 1password"
        return 0
    fi

    brew_install_cask 1password "1Password"
    print_status "Sign in to 1Password to enable browser and desktop integration"
}

# Podman is rootless on Linux; on macOS it needs a Linux VM, which is created
# and started here so `podman run` works right after setup.
install_podman() {
    print_section "Podman"

    brew_install_formula podman "Podman"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "podman machine init (if missing)"
        print_dry_run "podman machine start"
        return 0
    fi

    if ! podman machine inspect &>/dev/null; then
        print_status "Initializing Podman VM..."
        podman machine init 2>&1 | tee -a "${LOG_FILE}"
        print_success "Podman VM initialized"
    else
        print_skip "Podman VM"
    fi

    if [[ "$(podman machine inspect --format '{{.State}}' 2>/dev/null)" == "running" ]]; then
        print_skip "Podman VM (already running)"
    else
        print_status "Starting Podman VM..."
        podman machine start 2>&1 | tee -a "${LOG_FILE}"
        print_success "Podman VM started"
    fi

    print_success "Podman $(podman --version | awk '{print $3}') installed (rootless, runs a lightweight Linux VM)"
}

install_multipass() {
    print_section "Multipass"

    if cask_installed multipass; then
        print_skip "Multipass"
        return 0
    fi

    brew_install_cask multipass "Multipass"
    print_status "Launch a VM with: multipass launch --name dev"
}

install_twingate() {
    print_section "Twingate VPN Client"

    if cask_installed twingate; then
        print_skip "Twingate"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "brew install --cask twingate"
        print_dry_run "Open Twingate and sign in to network: ${TWINGATE_NETWORK}"
        return 0
    fi

    brew_install_cask twingate "Twingate"

    echo ""
    print_success "Twingate installed successfully!"
    print_status "Open Twingate and sign in to network: ${TWINGATE_NETWORK}"
    echo ""
}

install_postgresql() {
    print_section "PostgreSQL"

    brew_install_formula "${POSTGRES_FORMULA}" "PostgreSQL"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "brew services start ${POSTGRES_FORMULA}"
        return 0
    fi

    # postgresql@NN is keg-only, so its bin directory is added to PATH.
    local pg_bin="${HOMEBREW_PREFIX}/opt/${POSTGRES_FORMULA}/bin"
    add_profile_block "${HOME}/.zshrc" "${pg_bin}" \
        "# PostgreSQL" \
        "export PATH=\"${pg_bin}:\${PATH}\""
    export PATH="${pg_bin}:${PATH}"

    start_brew_service "${POSTGRES_FORMULA}"

    if command_exists psql; then
        print_success "PostgreSQL $(psql --version | awk '{print $3}') installed and running"
    fi
}

# =============================================================================
# Data-Driven Installers
# =============================================================================

install_simple_formulae() {
    print_section "Additional CLI Tools"

    local entry formula name
    for entry in "${SIMPLE_FORMULAE[@]}"; do
        IFS='|' read -r formula name <<< "${entry}"
        brew_install_formula "${formula}" "${name}"
    done
}

install_casks() {
    print_section "Applications (Homebrew casks)"

    if [[ "${INSTALL_APPS}" != true ]]; then
        print_warning "Skipping applications (disabled)"
        return 0
    fi

    local failed_apps=()
    local installed_count=0
    local skipped_count=0

    local entry cask name
    for entry in "${CASK_APPS[@]}"; do
        IFS='|' read -r cask name <<< "${entry}"

        if cask_installed "${cask}"; then
            print_skip "${name}"
            skipped_count=$((skipped_count + 1))
        elif brew_install_cask "${cask}" "${name}"; then
            installed_count=$((installed_count + 1))
        else
            failed_apps+=("${name}")
            log "ERROR" "Failed to install cask: ${cask} (${name})"
        fi
    done

    echo ""
    if [[ ${installed_count} -gt 0 ]]; then
        print_success "Newly installed: ${installed_count} apps"
    fi
    if [[ ${skipped_count} -gt 0 ]]; then
        print_status "Already installed: ${skipped_count} apps"
    fi
    if [[ ${#failed_apps[@]} -gt 0 ]]; then
        print_warning "Failed to install: ${failed_apps[*]}"
    fi
}

# =============================================================================
# Desktop Settings
# =============================================================================

read_default_bool() {
    local domain="$1"
    local key="$2"
    local value
    value="$(defaults read "${domain}" "${key}" 2>/dev/null || echo "0")"
    [[ "${value}" == "1" || "${value}" == "true" ]]
}

set_default_bool() {
    local domain="$1"
    local key="$2"
    local want="$3"
    local label="$4"
    local current_is_true=false

    if read_default_bool "${domain}" "${key}"; then
        current_is_true=true
    fi

    if [[ "${current_is_true}" == "${want}" ]]; then
        print_skip "${label} (already set)"
        return 1
    fi

    defaults write "${domain}" "${key}" -bool "${want}"
    print_success "${label} enabled"
    return 0
}

set_default_string() {
    local domain="$1"
    local key="$2"
    local want="$3"
    local label="$4"
    local current=""

    current="$(defaults read "${domain}" "${key}" 2>/dev/null || true)"
    if [[ "${current}" == "${want}" ]]; then
        print_skip "${label} (already set)"
        return 1
    fi

    defaults write "${domain}" "${key}" -string "${want}"
    print_success "${label} set"
    return 0
}

set_default_int() {
    local domain="$1"
    local key="$2"
    local want="$3"
    local label="$4"
    local current=""

    current="$(defaults read "${domain}" "${key}" 2>/dev/null || true)"
    if [[ "${current}" == "${want}" ]]; then
        print_skip "${label} (already set)"
        return 1
    fi

    defaults write "${domain}" "${key}" -int "${want}"
    print_success "${label} set"
    return 0
}

install_desktop_settings() {
    print_section "Desktop Settings (macOS)"

    if [[ "${INSTALL_DESKTOP_SETTINGS}" != true ]]; then
        print_warning "Skipping desktop settings (disabled)"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Configure macOS desktop settings (dark mode, dock auto-hide at the bottom, small icons, desktop volumes)"
        return 0
    fi

    local changes_made=0
    local dock_changed=false
    local finder_changed=false

    # Dark mode (GNOME's prefer-dark equivalent)
    local current_style
    current_style="$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")"
    if [[ "${current_style}" != "Dark" ]]; then
        print_status "Setting appearance to dark mode..."
        defaults write -g AppleInterfaceStyle -string Dark
        defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool false
        print_success "Dark mode enabled"
        changes_made=$((changes_made + 1))
    else
        print_skip "Dark mode (already enabled)"
    fi

    # Dock: auto-hide, bottom position, small icons (matches the Linux dock setup)
    if set_default_bool com.apple.dock autohide true "Dock auto-hide"; then
        dock_changed=true
        changes_made=$((changes_made + 1))
    fi
    if set_default_string com.apple.dock orientation bottom "Dock position (bottom)"; then
        dock_changed=true
        changes_made=$((changes_made + 1))
    fi
    if set_default_int com.apple.dock tilesize 16 "Dock icon size (smallest)"; then
        dock_changed=true
        changes_made=$((changes_made + 1))
    fi

    # Desktop icons: show mounted volumes. macOS always starts icons top-right,
    # so the GNOME start-corner setting has no equivalent, and there is no
    # home/trash icon toggle outside Finder's volume checkboxes.
    if set_default_bool com.apple.finder ShowExternalHardDrivesOnDesktop true "Desktop: external hard drives"; then
        finder_changed=true
        changes_made=$((changes_made + 1))
    fi
    if set_default_bool com.apple.finder ShowRemovableMediaOnDesktop true "Desktop: removable media"; then
        finder_changed=true
        changes_made=$((changes_made + 1))
    fi
    if set_default_bool com.apple.finder ShowHardDrivesOnDesktop false "Desktop: internal hard drives hidden"; then
        finder_changed=true
        changes_made=$((changes_made + 1))
    fi

    if [[ "${dock_changed}" == true ]]; then
        print_status "Restarting Dock..."
        killall Dock 2>/dev/null || true
    fi
    if [[ "${finder_changed}" == true ]]; then
        print_status "Restarting Finder..."
        killall Finder 2>/dev/null || true
    fi

    echo ""
    if [[ ${changes_made} -gt 0 ]]; then
        print_success "macOS desktop settings configured (${changes_made} changes made)"
        print_status "Some apps may need to be restarted for dark mode to apply"
    else
        print_status "All desktop settings already configured"
    fi
}

# =============================================================================
# Setup Helpers
# =============================================================================

setup_sudo_keepalive() {
    if [[ "${DRY_RUN}" == true ]]; then
        return 0
    fi

    # Homebrew casks install into /Applications and the OpenJDK symlink lands
    # in /Library, so keep the sudo timestamp alive across the whole run.
    if ! sudo -v; then
        print_error "Failed to obtain sudo privileges"
        exit 1
    fi

    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" || exit
    done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
}

# =============================================================================
# Main Execution
# =============================================================================

show_help() {
    cat <<'HELPEOF'
System Setup Script (macOS)
Configures a fresh Apple Silicon macOS installation with common development tools

Prerequisites:
  Apple Silicon Mac, Xcode 26+ with its developer tools selected

Usage: ./system-setup.sh [OPTIONS]
  --skip-apps               Skip GUI applications (Homebrew casks)
  --skip-desktop-settings   Skip macOS desktop customization (dark mode, dock)
  --skip-gitturtle          Skip building GitTurtle from source
  --dry-run                 Show what would be installed without making changes
  --help                    Show this help message
HELPEOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-apps)
                INSTALL_APPS=false
                shift
                ;;
            --skip-desktop-settings)
                INSTALL_DESKTOP_SETTINGS=false
                shift
                ;;
            --skip-gitturtle)
                INSTALL_GITTURTLE=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         System Setup Script (macOS)                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "${DRY_RUN}" == true ]]; then
        echo -e "${YELLOW}>>> DRY RUN MODE - No changes will be made <<<${NC}"
        echo ""
    fi

    print_status "Log file: ${LOG_FILE}"
    echo ""

    # Preflight: Apple Silicon + Xcode/dev tools are hard requirements
    check_platform

    # Homebrew is the package manager for everything below
    ensure_homebrew

    # Sudo setup (casks and the JDK symlink need it)
    setup_sudo_keepalive

    # --- Package Lists ---
    print_section "Package Lists"
    brew_update

    # --- Version Control ---
    install_git
    install_git_lfs

    # --- Languages & Runtimes ---
    install_nodejs
    install_bun
    install_rust
    install_jdk

    # --- Built From Source (needs Git and Rust above) ---
    install_gitturtle

    # --- Package Managers & CLI Tools ---
    install_npm_packages
    install_claude_code
    install_opencode
    install_codex

    # --- Security & Passwords ---
    install_1password

    # --- Containers, VMs & Infrastructure ---
    # Docker Engine is intentionally not installed: there is no native engine on
    # macOS; use Podman (or install Docker Desktop by hand if licensed).
    install_podman
    install_multipass
    install_twingate

    # --- Databases ---
    install_postgresql

    # --- Additional CLI Tools (FFmpeg, Go, wormhole, GitHub CLI, pnpm) ---
    install_simple_formulae

    # --- GUI Applications (browsers, editors, chat, media) ---
    install_casks

    # --- Desktop Customization ---
    install_desktop_settings

    # --- Cleanup ---
    print_section "System Cleanup"
    if [[ "${DRY_RUN}" != true ]]; then
        print_status "Removing unused dependencies and cached downloads..."
        brew_run autoremove || true
        brew_run cleanup -s || true
        print_success "Cleanup completed"
    else
        print_dry_run "brew autoremove and brew cleanup -s"
    fi

    # --- Summary ---
    print_section "Setup Complete"
    print_success "System setup finished successfully!"
    print_status "Log file saved to: ${LOG_FILE}"
    echo ""
    print_warning "Restart your terminal (or run 'source ~/.zshrc') to pick up PATH changes"
    echo ""
}

main "$@"
