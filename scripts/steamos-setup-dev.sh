#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 CouchPlay Contributors
#
# SteamOS Developer Setup Script
# Unlocks the read-only filesystem, initializes pacman, and installs build dependencies.
#

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 1. Platform Check
if ! grep -q "ID=steamos" /etc/os-release; then
    print_error "This script must be run on SteamOS."
    exit 1
fi

print_info "Starting SteamOS development environment setup..."

# 2. Disable read-only mode & stop systemd-sysext
print_info "Disabling SteamOS read-only filesystem lock..."
sudo steamos-readonly disable

print_info "Temporarily stopping systemd-sysext..."
sudo systemctl stop systemd-sysext

# 3. Initialize package manager keys
print_info "Initializing pacman keyring..."
sudo pacman-key --init
sudo pacman-key --populate archlinux
sudo pacman-key --populate holo

# 4. Install build dependencies
print_info "Installing development toolchain and dependencies..."
# Pipe empty lines to pacman to handle any prompts automatically
echo "




" | sudo pacman -S --noconfirm --needed base-devel cmake qt6-base ninja extra-cmake-modules qt6-tools qt6-declarative libglvnd mesa kf6 qqc2-desktop-style kglobalaccel kirigami gcc-libs openmp vulkan-headers glibc polkit-qt6 linux-api-headers

print_info "=========================================================="
print_info "SteamOS Native Build Environment Setup Complete!"
print_warn "The root filesystem is currently WRITABLE for compilation."
print_info "You can now run: cmake -B build && cmake --build build"
print_warn "When you are done, run: ./scripts/steamos-teardown-dev.sh"
print_info "=========================================================="
