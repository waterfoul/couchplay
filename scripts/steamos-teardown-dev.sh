#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 CouchPlay Contributors
#
# SteamOS Developer Teardown & Rollback Script
# Restores read-only filesystem lock, restarts systemd-sysext, and handles update branch switching.
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

print_info "Starting SteamOS development environment teardown/rollback..."

# 2. Re-enable read-only mode (idempotent)
print_info "Ensuring SteamOS read-only filesystem lock is enabled..."
sudo steamos-readonly enable || true

# 3. Restart systemd-sysext (idempotent)
print_info "Ensuring systemd-sysext is running..."
sudo systemctl start systemd-sysext || true

print_info "SteamOS Native Build Environment is locked."
echo ""

# 4. Check tracked update branch and prompt to switch
if command -v atomupd-manager &>/dev/null; then
    CURRENT_BRANCH=$(atomupd-manager tracked-branch 2>/dev/null || echo "stable")
    if [[ "$CURRENT_BRANCH" == "stable" ]]; then
        TARGET_BRANCH="beta"
    else
        TARGET_BRANCH="stable"
    fi

    print_info "Current tracked update branch: ${YELLOW}${CURRENT_BRANCH}${NC}"
    echo -n -e "${GREEN}[PROMPT]${NC} Would you like to switch to the '${YELLOW}${TARGET_BRANCH}${NC}' branch to trigger a system reset/update? [y/N] "
    read -r response </dev/tty

    if [[ "$response" =~ ^[Yy]$ ]]; then
        print_info "Switching update branch to ${YELLOW}${TARGET_BRANCH}${NC}..."
        sudo atomupd-manager switch-branch "$TARGET_BRANCH"
        
        echo -n -e "${GREEN}[PROMPT]${NC} Would you like to run 'steamos-update' and reboot now? [y/N] "
        read -r reboot_response </dev/tty
        
        if [[ "$reboot_response" =~ ^[Yy]$ ]]; then
            print_info "Running 'steamos-update' (this may take a few minutes)..."
            sudo steamos-update
            print_info "Rebooting system..."
            sudo reboot
        else
            print_warn "Branch updated. You must run 'steamos-update' and reboot manually to apply the changes."
        fi
    else
        print_info "No branch switch requested."
    fi
else
    print_warn "atomupd-manager not found. Skipping update branch checks."
fi

print_info "Teardown script completed. You can run this script again at any time."
