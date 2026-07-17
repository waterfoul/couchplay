#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2025 CouchPlay Contributors
#
# CouchPlay One-Liner Installer
#
# Downloads and installs CouchPlay from GitHub releases.
# This script must be run with root privileges.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hikaps/couchplay/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/hikaps/couchplay/main/scripts/install.sh | bash -s -- --beta
#   sudo ./install.sh --beta
#
# Requirements:
#   - curl: for downloading files
#   - tar: for extracting the release tarball
#   - sha256sum: for verifying checksums
#   - x86_64 architecture

# Define repo owner and name (overridable via environment variables)
REPO_OWNER="${REPO_OWNER:-hikaps}"
REPO_NAME="${REPO_NAME:-couchplay}"

# Re-run with sudo if not root (allows piped input to work with visible output)
if [[ $EUID -ne 0 ]]; then
    echo "Requesting sudo access to install CouchPlay..."
    # --beta means a develop build, so re-fetch the installer from develop; otherwise main.
    # We re-download because piping leaves no script on disk. Forward "$@" so flags
    # (e.g. --beta) survive the sudo escalation — previously they were silently dropped,
    # which made the documented --beta one-liner always install stable instead of beta.
    if [[ " $* " == *" --beta "* ]]; then
        INSTALLER_BRANCH="develop"
    else
        INSTALLER_BRANCH="main"
    fi
    TMP_SCRIPT=$(mktemp)
    curl -fsSL "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${INSTALLER_BRANCH}/scripts/install.sh" > "$TMP_SCRIPT"
    chmod +x "$TMP_SCRIPT"
    exec sudo REPO_OWNER="$REPO_OWNER" REPO_NAME="$REPO_NAME" "$TMP_SCRIPT" "$@"
fi

set -e
# =============================================================================
# Configuration
# =============================================================================

GITHUB_API="${GITHUB_API:-https://api.github.com}"

# Installation paths (overridable via environment)
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${BIN_DIR:-${PREFIX}/bin}"
LIBEXEC_DIR="${LIBEXEC_DIR:-${PREFIX}/libexec}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# Output Functions
# =============================================================================

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# =============================================================================
# Pre-flight Checks
# =============================================================================


check_root() {
    # Already running as root due to sudo re-exec at script start
    :
}


check_dependencies() {
    local missing_deps=()
    
    if ! command -v curl &>/dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v tar &>/dev/null; then
        missing_deps+=("tar")
    fi
    
    if ! command -v sha256sum &>/dev/null; then
        missing_deps+=("sha256sum")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Please install the missing dependencies and try again."
        echo ""
        echo "On Debian/Ubuntu:"
        echo "  sudo apt install ${missing_deps[*]}"
        echo ""
        echo "On Fedora/RHEL:"
        echo "  sudo dnf install ${missing_deps[*]}"
        echo ""
        echo "On Arch Linux:"
        echo "  sudo pacman -S ${missing_deps[*]}"
        exit 1
    fi

    # Check for runtime dependencies (warn but don't fail)
    if ! command -v gamescope &>/dev/null; then
        print_warn "gamescope is not installed. CouchPlay requires gamescope to launch game sessions."
        echo ""
        echo "On Debian/Ubuntu:"
        echo "  sudo apt install gamescope"
        echo ""
        echo "On Fedora:"
        echo "  sudo dnf install gamescope"
        echo ""
        echo "On Arch Linux:"
        echo "  sudo pacman -S gamescope"
    fi
}

check_architecture() {
    local arch
    arch=$(uname -m)
    
    if [[ "$arch" != "x86_64" ]]; then
        print_error "Unsupported architecture: $arch"
        echo ""
        echo "CouchPlay is currently only available for x86_64 (AMD64) systems."
        echo "Your system is running: $arch"
        echo ""
        echo "If you would like to see support for your architecture, please"
        echo "open an issue at: https://github.com/${REPO_OWNER}/${REPO_NAME}/issues"
        exit 1
    fi
    
    print_info "Architecture check passed: $arch"
}

check_binary_deps() {
    # The release tarball does NOT bundle runtime libraries; the helper and GUI link
    # against system Qt6, KDE Frameworks 6, Polkit and PipeWire. If a required shared
    # library is missing the helper fails to start with an opaque exit code (e.g. the
    # "Main process exited" / ERRNO 2 seen on minimal Arch installs). Detect missing
    # libs up front so the user gets a clear, actionable message instead.
    local extract_dir="$1"
    local bin_dir helper missing
    bin_dir=$(find "$extract_dir" -type d -name "bin" | head -1)
    [[ -z "$bin_dir" ]] && return 0
    helper="${bin_dir}/couchplay-helper"
    [[ -x "$helper" ]] || return 0

    if ! missing=$(ldd "$helper" 2>/dev/null | grep -i 'not found'); then
        return 0
    fi
    [[ -z "$missing" ]] && return 0

    print_error "The helper binary is missing required shared libraries on this system:"
    echo ""
    echo "$missing" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*=>.*//' | sort -u \
        | while IFS= read -r lib; do [[ -n "$lib" ]] && echo "  $lib"; done
    echo ""
    echo "The CouchPlay release does not bundle runtime libraries; it links against"
    echo "system Qt6, KDE Frameworks 6, Polkit and PipeWire. Install the packages"
    echo "providing the libraries listed above, then re-run this installer."
    echo ""
    echo "On Arch Linux / CachyOS:"
    echo "  sudo pacman -S qt6-base polkit-qt6 kirigami pipewire"
    echo ""
    echo "On Fedora:"
    echo "  sudo dnf install qt6-qtbase polkit-qt6-1-devel kf6-kirigami pipewire"
    echo ""
    echo "On Debian/Ubuntu:"
    echo "  sudo apt install qt6-base-dev libpolkit-qt6-1-1 kirigami pipewire"
    exit 1
}

# =============================================================================
# GitHub API Functions
# =============================================================================

get_latest_release() {
    # Fetches the latest stable release metadata from GitHub Releases API
    # The /releases/latest endpoint excludes pre-releases
    # Returns JSON with: tag_name, name, assets[], etc.
    
    local api_url="${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    local response
    local http_code
    
    print_info "Fetching latest release information..."
    
    # Use curl with silent mode, but capture HTTP status code
    response=$(curl -sL -w "\n%{http_code}" "$api_url" 2>/dev/null)
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" != "200" ]]; then
        {
            print_error "Failed to fetch release information (HTTP $http_code)"
            echo ""
            echo "This could mean:"
            echo "  - No releases have been published yet"
            echo "  - GitHub API rate limit exceeded"
            echo "  - Network connectivity issues"
            echo ""
            echo "Please check: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
        } >&2
        exit 1
    fi
    
    echo "$response"
}

get_beta_release() {
    # Fetches the beta (pre-release) metadata from GitHub Releases API
    # Uses the /releases/tags/beta endpoint to get the rolling beta release
    # Returns JSON with: tag_name, name, assets[], etc.

    local api_url="${GITHUB_API}/repos/${REPO_OWNER}/${REPO_NAME}/releases/tags/beta"
    local response
    local http_code

    print_info "Fetching beta release information..."

    response=$(curl -sL -w "\n%{http_code}" "$api_url" 2>/dev/null)
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        {
            print_error "Failed to fetch beta release information (HTTP $http_code)"
            echo ""
            echo "This could mean:"
            echo "  - No beta release has been published yet"
            echo "  - GitHub API rate limit exceeded"
            echo "  - Network connectivity issues"
            echo ""
            echo "Please check: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/beta"
        } >&2
        exit 1
    fi

    echo "$response"
}

get_release_tag() {
    # Extracts tag_name from release JSON
    echo "$1" | grep -m1 '"tag_name"' | cut -d'"' -f4
}

get_release_name() {
    # Extracts release name from release JSON
    echo "$1" | grep -m1 '"name"' | cut -d'"' -f4
}

get_asset_url() {
    # Extracts browser_download_url for a matching asset pattern
    # Usage: get_asset_url "$release_json" "couchplay-.*-linux.tar.gz"
    local release_json="$1"
    local pattern="$2"
    
    echo "$release_json" | grep -o "\"browser_download_url\": \"[^\"]*\"" | \
        grep -E "$pattern" | \
        head -1 | \
        cut -d'"' -f4
}

# =============================================================================
# Download and Install Functions
# =============================================================================

download_file() {
    # Downloads a file from URL to specified output path
    # Returns 0 on success, 1 on failure
    local url="$1"
    local output="$2"
    
    print_info "Downloading: $url"
    
    if ! curl -fsSL "$url" -o "$output"; then
        print_error "Failed to download: $url"
        return 1
    fi
    
    # Ensure the real user can read/access this file (needed for Flatpak install & Steam artwork)
    chown "$REAL_USER:$REAL_USER" "$output" 2>/dev/null || true
    chmod 644 "$output" 2>/dev/null || true
    return 0
}

verify_checksum() {
    # Verifies the tarball checksum against the .sha256 file
    # The .sha256 file format: <hash>  <filename>
    # Uses sha256sum -c for verification
    # FAILS HARD on mismatch or missing checksum file
    local tarball="$1"
    local checksum_file="$2"
    local tarball_dir
    
    print_info "Verifying checksum..."
    
    # Check that checksum file exists
    if [[ ! -f "$checksum_file" ]]; then
        print_error "Checksum file not found: $checksum_file"
        print_error "Cannot verify tarball integrity - aborting for safety"
        exit 1
    fi
    
    # Check that tarball exists
    if [[ ! -f "$tarball" ]]; then
        print_error "Tarball not found: $tarball"
        exit 1
    fi
    
    # sha256sum -c expects to be run from the directory containing the file
    # The .sha256 file contains relative filenames
    tarball_dir=$(dirname "$tarball")
    
    # Run verification from the tarball directory
    if ! (cd "$tarball_dir" && sha256sum -c "$(basename "$checksum_file")" --strict --quiet 2>/dev/null); then
        print_error "Checksum verification FAILED!"
        print_error "The downloaded file may be corrupted or tampered with."
        print_error "Aborting installation for safety."
        exit 1
    fi
    
    print_info "Checksum verification passed"
    return 0
}

extract_tarball() {
    # Extracts the tarball to the specified directory
    local tarball="$1"
    local extract_dir="$2"
    
    print_info "Extracting tarball..."
    
    if ! tar -xJf "$tarball" -C "$extract_dir"; then
        print_error "Failed to extract tarball"
        return 1
    fi
    
    return 0
}

install_binary() {
    # Installs the main couchplay binary and gamemode launcher to BIN_DIR
    # Uses 'install' command for proper permissions
    local extract_dir="$1"
    local binary_name
    
    # The tarball extracts to a subdirectory named couchplay-x86_64 or similar
    # Find the actual extracted directory containing bin/
    local bin_dir
    bin_dir=$(find "$extract_dir" -type d -name "bin" | head -1)
    
    if [[ -z "$bin_dir" ]]; then
        print_error "Could not find bin/ directory in extracted tarball"
        return 1
    fi
    
    # Install the main binary
    print_info "Installing couchplay binary to ${BIN_DIR}"
    
    # Create BIN_DIR if it doesn't exist (idempotent)
    mkdir -p "$BIN_DIR"
    
    # Use install command for proper permissions (755)
    if ! install -Dm755 "${bin_dir}/couchplay" "${BIN_DIR}/couchplay"; then
        print_error "Failed to install couchplay binary"
        return 1
    fi
    
    # Install the Game Mode launcher script if present
    local scripts_dir
    scripts_dir=$(find "$extract_dir" -type d -name "scripts" | head -1)
    if [[ -n "$scripts_dir" ]] && [[ -f "${scripts_dir}/couchplay-gamemode.sh" ]]; then
        print_info "Installing Game Mode launcher to ${BIN_DIR}"
        install -Dm755 "${scripts_dir}/couchplay-gamemode.sh" "${BIN_DIR}/couchplay-gamemode"
    fi
    
    print_info "Binary installed successfully"
    return 0
}

install_data() {
    # Installs desktop file, icon, and metainfo for desktop integration
    local extract_dir="$1"
    
    # Find the extracted directory containing data/
    local data_dir
    data_dir=$(find "$extract_dir" -type d -name "data" | head -1)
    
    if [[ -z "$data_dir" ]]; then
        print_warn "Could not find data/ directory in extracted tarball — skipping desktop integration"
        return 0
    fi
    
    # Install desktop file
    local desktop_src="${data_dir}/io.github.hikaps.couchplay.desktop"
    if [[ -f "$desktop_src" ]]; then
        print_info "Installing desktop file..."
        install -Dm644 "$desktop_src" "${PREFIX}/share/applications/io.github.hikaps.couchplay.desktop"
    fi
    
    # Install icon
    local icon_src="${data_dir}/icons/io.github.hikaps.couchplay.png"
    if [[ -f "$icon_src" ]]; then
        print_info "Installing icon..."
        install -Dm644 "$icon_src" "${PREFIX}/share/icons/hicolor/512x512/apps/io.github.hikaps.couchplay.png"
    fi
    
    # Install metainfo
    local metainfo_src="${data_dir}/io.github.hikaps.couchplay.metainfo.xml"
    if [[ -f "$metainfo_src" ]]; then
        print_info "Installing metainfo..."
        install -Dm644 "$metainfo_src" "${PREFIX}/share/metainfo/io.github.hikaps.couchplay.metainfo.xml"
    fi
    
    # Update icon cache and desktop database (non-fatal)
    if command -v gtk-update-icon-cache &>/dev/null; then
        gtk-update-icon-cache -f -t "${PREFIX}/share/icons/hicolor" 2>/dev/null || true
    fi
    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "${PREFIX}/share/applications" 2>/dev/null || true
    fi
    
    print_info "Desktop integration installed successfully"
    return 0
}

install_helper() {
    # Runs the install-helper.sh script from the extracted release directory
    # This installs the privileged helper service, D-Bus config, and polkit policy
    local extract_dir="$1"
    
    # Find the install-helper.sh script
    local helper_script
    helper_script=$(find "$extract_dir" -name "install-helper.sh" -type f | head -1)
    
    if [[ -z "$helper_script" ]]; then
        print_error "Could not find install-helper.sh in extracted tarball"
        return 1
    fi
    
    local helper_dir
    helper_dir=$(dirname "$helper_script")
    
    print_info "Installing helper service..."
    
    # Run the helper installer from its directory
    # The helper script expects to be run from its own directory
    local current_dir
    current_dir=$(pwd)
    
    cd "$helper_dir"
    
    if ! ./install-helper.sh install; then
        cd "$current_dir"
        print_error "Helper installation failed"
        return 1
    fi
    
    cd "$current_dir"
    
    print_info "Helper service installed successfully"
    return 0
}

cleanup() {
    # Cleans up the temporary directory
    # Safe to call multiple times
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        print_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

# Determine the real user calling the script (for SteamOS home directory persistence)
REAL_USER="${SUDO_USER:-deck}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_HOME="${REAL_HOME:-/home/deck}"

# Global variables for Steam shortcut setup
SKIP_STEAM=false
FORCE_STEAM=false

configure_steam_shortcut() {
    local BETA="$1"
    
    if $SKIP_STEAM; then
        print_info "Skipping Steam shortcut setup as requested."
        return 0
    fi

    # Find all Steam config directories under REAL_HOME
    local possible_roots=(
        "${REAL_HOME}/.steam/steam/userdata"
        "${REAL_HOME}/.local/share/Steam/userdata"
        "${REAL_HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata"
    )
    
    local config_dirs=()
    for root in "${possible_roots[@]}"; do
        if [[ -d "$root" ]]; then
            # Find subdirectories that are digits (representing user IDs)
            for d in "$root"/*; do
                if [[ -d "$d" && "$(basename "$d")" =~ ^[0-9]+$ ]]; then
                    if [[ -d "$d/config" ]]; then
                        config_dirs+=("$d/config")
                    fi
                fi
            done
        fi
    done
    
    if [[ ${#config_dirs[@]} -eq 0 ]]; then
        print_warn "No Steam userdata directories found. Skipping Steam shortcut configuration."
        return 0
    fi

    local steam_running=false
    if pgrep -x "steam" >/dev/null; then
        steam_running=true
    fi

    local proceed=false
    local close_steam=false

    if $FORCE_STEAM; then
        proceed=true
        if $steam_running; then
            close_steam=true
        fi
    else
        # Prompt user if interactive
        if [[ -t 0 ]]; then
            if $steam_running; then
                echo -e "${YELLOW}[PROMPT]${NC} Steam is currently running. Steam must be closed to apply new shortcuts."
                read -p "Would you like to close Steam and add CouchPlay to your Steam library? (y/n) [n]: " -r
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    proceed=true
                    close_steam=true
                fi
            else
                read -p "Would you like to add CouchPlay to your Steam library and set up its custom artwork? (y/n) [y]: " -r
                # Default is yes if they just press enter or type y/Y
                if [[ -z "$REPLY" || "$REPLY" =~ ^[Yy]$ ]]; then
                    proceed=true
                fi
            fi
        else
            # Non-interactive fallback
            if $steam_running; then
                print_warn "Steam is running and script is non-interactive. Skipping Steam shortcut configuration."
                proceed=false
            else
                print_info "Running non-interactively. Safe to add shortcut since Steam is not running."
                proceed=true
            fi
        fi
    fi

    if ! $proceed; then
        print_info "Steam shortcut configuration skipped."
        return 0
    fi

    # Close Steam if required
    local steam_was_closed=false
    if $close_steam && $steam_running; then
        print_info "Closing Steam..."
        pkill -x steam || killall steam || true
        steam_was_closed=true
        sleep 3
    fi

    # Download and prepare all specialized artwork items to TEMP_DIR
    local branch="main"
    if [[ "$BETA" == "true" ]]; then
        branch="develop"
    fi

    # Format: "repo_filename:target_suffix:target_extension"
    local artwork_items=(
        "steam_vertical_capsule.jpg:p:.jpg"
        "steam_horizontal_grid.jpg::.jpg"
        "steam_hero.jpg:_hero:.jpg"
        "steam_logo.png:_logo:.png"
        "icon.png:_icon:.png"
    )

    for item in "${artwork_items[@]}"; do
        IFS=":" read -r repo_file suffix ext <<< "$item"
        local local_tmp="${TEMP_DIR}/${repo_file}"
        local download_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${branch}/assets/${repo_file}"
        
        print_info "Preparing artwork: ${repo_file}..."
        if ! download_file "$download_url" "$local_tmp" &>/dev/null; then
            # Check local checkouts or fallbacks
            local local_fallback="./assets/${repo_file}"
            local system_flatpak_icon="/var/lib/flatpak/exports/share/icons/hicolor/512x512/apps/io.github.hikaps.couchplay.png"
            local user_flatpak_icon="${REAL_HOME}/.local/share/flatpak/exports/share/icons/hicolor/512x512/apps/io.github.hikaps.couchplay.png"
            
            if [[ -f "$local_fallback" ]]; then
                cp "$local_fallback" "$local_tmp"
            elif [[ "$repo_file" == "icon.png" && -f "$user_flatpak_icon" ]]; then
                cp "$user_flatpak_icon" "$local_tmp"
            elif [[ "$repo_file" == "icon.png" && -f "$system_flatpak_icon" ]]; then
                cp "$system_flatpak_icon" "$local_tmp"
            fi
        fi
    done

    # Inline Python script to update shortcuts.vdf and return AppID
    local py_script
    py_script=$(cat <<'EOF'
import os
import sys
import struct
import binascii
from pathlib import Path

APP_NAME = "CouchPlay"
EXE = "/usr/bin/flatpak"
START_DIR = "/usr/bin/"
LAUNCH_OPTIONS = '"run" "--branch=stable" "--arch=x86_64" "--command=couchplay-gamemode" "io.github.hikaps.couchplay"'
SHORTCUT_PATH = ""
# Try to find the exported .desktop file for the shortcut path
import glob
desktop_patterns = [
    "/var/lib/flatpak/app/io.github.hikaps.couchplay/x86_64/stable/*/export/share/applications/io.github.hikaps.couchplay.desktop",
    os.path.expanduser("~/.local/share/flatpak/app/io.github.hikaps.couchplay/x86_64/stable/*/export/share/applications/io.github.hikaps.couchplay.desktop"),
]
for pat in desktop_patterns:
    matches = glob.glob(pat)
    if matches:
        SHORTCUT_PATH = matches[0]
        break

def calculate_appid(exe, appname):
    salt = f'"{exe}"{appname}'.encode("utf-8")
    return (binascii.crc32(salt) | 0x80000000) & 0xffffffff

def add_shortcut(vdf_path):
    if not vdf_path.exists():
        vdf_path.parent.mkdir(parents=True, exist_ok=True)
        data = b"\x00shortcuts\x00\x08\x08"
    else:
        with open(vdf_path, "rb") as f:
            data = f.read()
            
    if f"\x01appname\x00{APP_NAME}\x00".encode("utf-8") in data:
        return calculate_appid(EXE, APP_NAME), False
        
    idx = 0
    while True:
        if f"\x00{idx}\x00".encode("ascii") in data:
            idx += 1
        else:
            break
            
    entry = bytearray()
    entry.append(0x00)
    entry.extend(str(idx).encode("ascii") + b"\x00")
    
    appid = calculate_appid(EXE, APP_NAME)
    entry.append(0x02)
    entry.extend(b"appid\x00")
    entry.extend(struct.pack("<I", appid))
    
    entry.append(0x01)
    entry.extend(b"appname\x00")
    entry.extend(APP_NAME.encode("utf-8") + b"\x00")
    
    entry.append(0x01)
    entry.extend(b"Exe\x00")
    entry.extend(f'"{EXE}"'.encode("utf-8") + b"\x00")
    
    entry.append(0x01)
    entry.extend(b"StartDir\x00")
    entry.extend(f'"{START_DIR}"'.encode("utf-8") + b"\x00")
    
    icon_path = str(vdf_path.parent / f"grid/{appid}_icon.png")
    entry.append(0x01)
    entry.extend(b"icon\x00")
    entry.extend(icon_path.encode("utf-8") + b"\x00")
    
    entry.append(0x01)
    entry.extend(b"ShortcutPath\x00")
    entry.extend(SHORTCUT_PATH.encode("utf-8") + b"\x00")
    
    entry.append(0x01)
    entry.extend(b"LaunchOptions\x00")
    entry.extend(LAUNCH_OPTIONS.encode("utf-8") + b"\x00")
    
    entry.append(0x02)
    entry.extend(b"IsShortcut\x00")
    entry.extend(struct.pack("<I", 1))
    
    entry.append(0x08)
    
    if data.endswith(b"\x08\x08"):
        new_data = data[:-2] + entry + b"\x08\x08"
    else:
        new_data = data.rstrip(b"\x08") + entry + b"\x08\x08"
        
    with open(vdf_path, "wb") as f:
        f.write(new_data)
    return appid, True

try:
    vdf_file = Path(sys.argv[1])
    appid, added = add_shortcut(vdf_file)
    print(f"{appid}:{added}")
except Exception as e:
    print(f"ERROR:{e}", file=sys.stderr)
    sys.exit(1)
EOF
)

    for cfg_dir in "${config_dirs[@]}"; do
        local shortcuts_file="${cfg_dir}/shortcuts.vdf"
        print_info "Adding shortcut to ${shortcuts_file}..."
        
        local py_out
        py_out=$(sudo -u "$REAL_USER" python3 -c "$py_script" "$shortcuts_file" 2>/dev/null || true)
        
        if [[ "$py_out" =~ ^[0-9]+:.* ]]; then
            local appid="${py_out%%:*}"
            local added="${py_out##*:}"
            
            # Setup grid artwork
            local grid_dir="${cfg_dir}/grid"
            sudo -u "$REAL_USER" mkdir -p "$grid_dir"
            
            local copied_any=false
            for item in "${artwork_items[@]}"; do
                IFS=":" read -r repo_file suffix ext <<< "$item"
                local local_tmp="${TEMP_DIR}/${repo_file}"
                local dest_file="${grid_dir}/${appid}${suffix}${ext}"
                
                if [[ -f "$local_tmp" ]]; then
                    sudo -u "$REAL_USER" cp "$local_tmp" "$dest_file"
                    copied_any=true
                else
                    # Fallback to copy the icon if this specific layout is missing
                    local icon_tmp="${TEMP_DIR}/icon.png"
                    if [[ -f "$icon_tmp" ]]; then
                        local dest_png_file="${grid_dir}/${appid}${suffix}.png"
                        sudo -u "$REAL_USER" cp "$icon_tmp" "$dest_png_file"
                        copied_any=true
                    fi
                fi
            done
            
            if $copied_any; then
                print_info "Custom artwork set up for Steam Game Mode."
            fi
        else
            print_warn "Could not configure shortcut in ${shortcuts_file}. Check that Python is installed."
        fi
    done

    # Restart Steam if we closed it
    if $steam_was_closed; then
        print_info "Restarting Steam..."
        sudo -u "$REAL_USER" nohup steam >/dev/null 2>&1 &
    fi
}

# =============================================================================
# Installation Pathways
# =============================================================================

install_sysext() {
    local BETA="$1"
    local release_json="$2"
    local tag_name="$3"
    
    print_info "Installing via SteamOS System Extension (sysext)..."
    
    # Get asset URLs
    local raw_url checksum_url flatpak_url flatpak_checksum_url
    raw_url=$(get_asset_url "$release_json" "couchplay\.steamos\.raw")
    checksum_url=$(get_asset_url "$release_json" "couchplay\.steamos\.sha256")
    flatpak_url=$(get_asset_url "$release_json" "couchplay\.flatpak")
    flatpak_checksum_url=$(get_asset_url "$release_json" "couchplay\.flatpak\.sha256")
    
    if [[ -z "$raw_url" ]]; then
        print_error "Could not find couchplay.steamos.raw asset in release"
        exit 1
    fi
    if [[ -z "$checksum_url" ]]; then
        print_error "Could not find couchplay.steamos.sha256 asset in release"
        exit 1
    fi
    if [[ -z "$flatpak_url" ]]; then
        print_error "Could not find couchplay.flatpak asset in release"
        exit 1
    fi
    if [[ -z "$flatpak_checksum_url" ]]; then
        print_error "Could not find couchplay.flatpak.sha256 asset in release"
        exit 1
    fi
    
    # Setup temporary directory and cleanup trap
    TEMP_DIR=$(mktemp -d)
    chmod 755 "$TEMP_DIR"
    chown "$REAL_USER:$REAL_USER" "$TEMP_DIR" 2>/dev/null || true
    trap cleanup EXIT
    
    local raw_file="${TEMP_DIR}/couchplay.steamos.raw"
    local checksum_file="${TEMP_DIR}/couchplay.steamos.sha256"
    local flatpak_file="${TEMP_DIR}/couchplay.flatpak"
    local flatpak_checksum_file="${TEMP_DIR}/couchplay.flatpak.sha256"
    
    # Download files
    if ! download_file "$raw_url" "$raw_file"; then
        exit 1
    fi
    if ! download_file "$checksum_url" "$checksum_file"; then
        exit 1
    fi
    if ! download_file "$flatpak_url" "$flatpak_file"; then
        exit 1
    fi
    if ! download_file "$flatpak_checksum_url" "$flatpak_checksum_file"; then
        exit 1
    fi
    
    # Verify checksum
    verify_checksum "$raw_file" "$checksum_file"
    verify_checksum "$flatpak_file" "$flatpak_checksum_file"
    
    # 1. Install Flatpak
    print_info "Installing Flatpak bundle..."
    if ! command -v flatpak &>/dev/null; then
        print_error "flatpak command not found. Please install flatpak first."
        exit 1
    fi
    # Ensure the user Flatpak repository is in a clean state
    print_info "Repairing user Flatpak repository..."
    sudo -u "$REAL_USER" flatpak repair --user >/dev/null 2>&1 || true

    print_info "Ensuring org.kde.Platform 6.10 is installed..."
    sudo -u "$REAL_USER" flatpak install --user --noninteractive -y flathub org.kde.Platform/x86_64/6.10

    # Try installing the bundle
    if ! sudo -u "$REAL_USER" flatpak install --user --noninteractive --reinstall -y "$flatpak_file"; then
        print_warn "Flatpak bundle installation failed. Attempting deep clean and retry..."
        
        # Try to uninstall any existing/conflicting installations of the app
        sudo -u "$REAL_USER" flatpak uninstall --user --noninteractive -y io.github.hikaps.couchplay >/dev/null 2>&1 || true
        
        # Forcefully remove leftover files/directories that Flatpak got stuck on
        rm -rf "${REAL_HOME}/.local/share/flatpak/app/io.github.hikaps.couchplay"
        
        # Repair again to ensure metadata matches the filesystem state
        sudo -u "$REAL_USER" flatpak repair --user >/dev/null 2>&1 || true
        
        # Retry the installation
        print_info "Retrying Flatpak bundle installation..."
        sudo -u "$REAL_USER" flatpak install --user --noninteractive --reinstall -y "$flatpak_file"
    fi
    
    # Stop existing CouchPlay helper service and systemd-sysext before upgrading
    print_info "Stopping active CouchPlay services..."
    systemctl stop couchplay-helper.service >/dev/null 2>&1 || true
    systemctl stop systemd-sysext >/dev/null 2>&1 || true
    
    # Clear out any legacy layout folders or old raw files
    rm -rf "$REAL_HOME/.couchplay-extension"
    rm -f "$REAL_HOME/.couchplay.raw"
    rm -f "$REAL_HOME/.couchplay.steamos.raw"
    rm -f /var/lib/extensions/couchplay.raw
    rm -f /var/lib/extensions/couchplay.steamos.raw
    
    # Deploy the new pre-built extension
    print_info "Deploying system extension..."
    mv "$raw_file" "$REAL_HOME/.couchplay.steamos.raw"
    chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.couchplay.steamos.raw"
    
    mkdir -p /var/lib/extensions
    ln -s "$REAL_HOME/.couchplay.steamos.raw" /var/lib/extensions/couchplay.steamos.raw
    
    # Load and enable the system extension
    print_info "Merging system extension..."
    systemctl enable systemd-sysext
    systemctl restart systemd-sysext
    
    # Reload D-Bus configuration to discover the new system service policy
    print_info "Reloading D-Bus daemon..."
    systemctl reload dbus
    
    # Start the helper daemon
    print_info "Starting couchplay-helper service..."
    systemctl daemon-reload
    systemctl restart couchplay-helper.service
    
    # Configure controller hidraw udev rules
    print_info "Configuring udev rules..."
    echo 'KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0666", TAG+="uaccess", TAG+="seat"' | tee /etc/udev/rules.d/99-couchplay-hidraw.rules
    udevadm control --reload-rules
    udevadm trigger
    
    # Configure Steam shortcut and artwork
    configure_steam_shortcut "$BETA" || true
    
    echo ""
    print_info "=========================================="
    print_info "CouchPlay $tag_name installed successfully!"
    print_info "=========================================="
    echo ""
    echo "You can now run CouchPlay from your application launcher or terminal:"
    echo "  couchplay"
    echo ""
}

install_tarball() {
    local BETA="$1"
    local release_json="$2"
    local tag_name="$3"
    
    print_info "Installing via traditional release tarball..."
    
    # Get asset URLs
    local tarball_url checksum_url
    tarball_url=$(get_asset_url "$release_json" "couchplay-x86_64\.tar\.xz")
    checksum_url=$(get_asset_url "$release_json" "couchplay-x86_64\.sha256")
    
    if [[ -z "$tarball_url" ]]; then
        print_error "Could not find tarball asset in release"
        exit 1
    fi
    
    if [[ -z "$checksum_url" ]]; then
        print_error "Could not find checksum asset in release"
        print_error "Refusing to install without checksum verification"
        exit 1
    fi
    
    print_info "Tarball: $tarball_url"
    print_info "Checksum: $checksum_url"
    
    # Setup temporary directory and cleanup trap
    TEMP_DIR=$(mktemp -d)
    chmod 755 "$TEMP_DIR"
    chown "$REAL_USER:$REAL_USER" "$TEMP_DIR" 2>/dev/null || true
    trap cleanup EXIT
    
    local tarball_file="${TEMP_DIR}/couchplay-x86_64.tar.xz"
    local checksum_file="${TEMP_DIR}/couchplay-x86_64.sha256"
    local extract_dir="${TEMP_DIR}/extract"
    
    mkdir -p "$extract_dir"
    
    # Download files
    echo ""
    if ! download_file "$tarball_url" "$tarball_file"; then
        exit 1
    fi
    
    if ! download_file "$checksum_url" "$checksum_file"; then
        exit 1
    fi
    
    # Verify checksum (fails hard on mismatch)
    echo ""
    verify_checksum "$tarball_file" "$checksum_file"
    
    # Extract tarball
    echo ""
    if ! extract_tarball "$tarball_file" "$extract_dir"; then
        exit 1
    fi

    # Verify the helper's runtime libraries are present (the tarball doesn't bundle them).
    check_binary_deps "$extract_dir"
    
    # Install main binary
    echo ""
    if ! install_binary "$extract_dir"; then
        exit 1
    fi

    # Install desktop file, icon, and metainfo
    echo ""
    if ! install_data "$extract_dir"; then
        exit 1
    fi

    # Install helper service (D-Bus, polkit, etc.)
    echo ""
    if ! install_helper "$extract_dir"; then
        exit 1
    fi
    
    # Configure Steam shortcut and artwork
    configure_steam_shortcut "$BETA" || true
    
    # Success!
    echo ""
    print_info "=========================================="
    print_info "CouchPlay $tag_name installed successfully!"
    print_info "=========================================="
    echo ""
    echo "You can now run CouchPlay with:"
    echo "  couchplay"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    local BETA=false
    local FORCE_SYSEXT=false
    local FORCE_TARBALL=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --beta) BETA=true; shift ;;
            --sysext) FORCE_SYSEXT=true; shift ;;
            --tarball) FORCE_TARBALL=true; shift ;;
            --skip-steam) SKIP_STEAM=true; shift ;;
            --force-steam) FORCE_STEAM=true; shift ;;
            *) shift ;;
        esac
    done

    print_info "CouchPlay Installer"
    echo ""
    
    # Pre-flight checks
    check_root
    check_dependencies
    check_architecture
    
    echo ""
    
    # Get release info (beta or stable)
    local release_json
    if $BETA; then
        release_json=$(get_beta_release)
        print_warn "Installing BETA build from develop — not a stable release!"
    else
        release_json=$(get_latest_release)
    fi
    
    local tag_name
    tag_name=$(get_release_tag "$release_json")
    print_info "Latest release: $tag_name"
    
    # Determine installation pathway
    local USE_SYSEXT=false
    if $FORCE_SYSEXT; then
        USE_SYSEXT=true
    elif $FORCE_TARBALL; then
        USE_SYSEXT=false
    else
        # Auto-detect SteamOS
        if [[ -f /etc/os-release ]] && grep -q "ID=steamos" /etc/os-release; then
            USE_SYSEXT=true
        fi
    fi
    
    if $USE_SYSEXT; then
        install_sysext "$BETA" "$release_json" "$tag_name"
    else
        install_tarball "$BETA" "$release_json" "$tag_name"
    fi
}

# Run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
