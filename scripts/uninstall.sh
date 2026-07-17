#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2025 CouchPlay Contributors
#
# CouchPlay Uninstaller Script
#
# Removes all files, configurations, system extensions, services,
# and shortcuts installed by the CouchPlay installer.
#
# This script must be run with root privileges.
#
# Usage:
#   sudo ./uninstall.sh [--remove-users] [--remove-data]
#

# Re-run with sudo if not root
if [[ $EUID -ne 0 ]]; then
    echo "Requesting sudo access to uninstall CouchPlay..."
    exec sudo "$0" "$@"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Determine the real user calling the script
REAL_USER="${SUDO_USER:-deck}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_HOME="${REAL_HOME:-/home/deck}"

# Installation paths (overridable via environment)
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${BIN_DIR:-${PREFIX}/bin}"
LIBEXEC_DIR="${LIBEXEC_DIR:-${PREFIX}/libexec}"
LIB_DIR="${LIB_DIR:-${PREFIX}/lib/couchplay}"
DBUS_SYSTEM_DIR="${DBUS_SYSTEM_DIR:-/etc/dbus-1/system.d}"
DBUS_SERVICE_DIR="${DBUS_SERVICE_DIR:-${PREFIX}/share/dbus-1/system-services}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
POLKIT_DIR_USR="/usr/share/polkit-1/actions"
POLKIT_DIR_ETC="/etc/polkit-1/actions"

print_info "CouchPlay Uninstaller"
echo ""

# =============================================================================
# Stop & Disable Service
# =============================================================================
print_info "Stopping and disabling couchplay-helper service if running..."
systemctl stop couchplay-helper.service 2>/dev/null || true
systemctl disable couchplay-helper.service 2>/dev/null || true

# =============================================================================
# Pathway 1: SteamOS (sysext) Pathway Cleanup
# =============================================================================
# Check if system extension was installed
SYSEXT_DETECTED=false
if [[ -L /var/lib/extensions/couchplay.steamos.raw || -f /var/lib/extensions/couchplay.steamos.raw || \
      -L /var/lib/extensions/couchplay.raw || -f /var/lib/extensions/couchplay.raw || \
      -f "$REAL_HOME/.couchplay.steamos.raw" || -f "$REAL_HOME/.couchplay.raw" || \
      -d "$REAL_HOME/.couchplay-extension" ]]; then
    SYSEXT_DETECTED=true
fi

if $SYSEXT_DETECTED; then
    print_info "Cleaning up SteamOS system extension files..."
    
    # Temporarily stop systemd-sysext to allow unmerging cleanly
    systemctl stop systemd-sysext 2>/dev/null || true

    rm -f /var/lib/extensions/couchplay.steamos.raw || true
    rm -f /var/lib/extensions/couchplay.raw || true
    rm -f "$REAL_HOME/.couchplay.steamos.raw" || true
    rm -f "$REAL_HOME/.couchplay.raw" || true
    rm -rf "$REAL_HOME/.couchplay-extension" || true

    # Restart systemd-sysext to apply the unmerge
    systemctl start systemd-sysext 2>/dev/null || true
    systemctl restart systemd-sysext 2>/dev/null || true
fi

# Uninstall Flatpak bundle if present
if command -v flatpak &>/dev/null; then
    if sudo -u "$REAL_USER" flatpak info io.github.hikaps.couchplay &>/dev/null; then
        print_info "Uninstalling Flatpak bundle (io.github.hikaps.couchplay)..."
        sudo -u "$REAL_USER" flatpak uninstall --user -y io.github.hikaps.couchplay || true
    fi
    # Force clean up any leftover app files and repair repository to ensure clean state
    rm -rf "${REAL_HOME}/.local/share/flatpak/app/io.github.hikaps.couchplay"
    sudo -u "$REAL_USER" flatpak repair --user >/dev/null 2>&1 || true
fi

# Remove udev rules
if [[ -f /etc/udev/rules.d/99-couchplay-hidraw.rules ]]; then
    print_info "Removing udev rules..."
    rm -f /etc/udev/rules.d/99-couchplay-hidraw.rules || true
    if command -v udevadm &>/dev/null; then
        udevadm control --reload-rules || true
        udevadm trigger || true
    fi
fi

# =============================================================================
# Pathway 2: Traditional (Tarball) Pathway Cleanup
# =============================================================================
print_info "Cleaning up standalone/traditional installation files..."

# Remove binaries
rm -f "${BIN_DIR}/couchplay" || true
rm -f "${BIN_DIR}/couchplay-gamemode" || true

# Remove desktop metadata files
rm -f "${PREFIX}/share/applications/io.github.hikaps.couchplay.desktop" || true
rm -f "${PREFIX}/share/icons/hicolor/512x512/apps/io.github.hikaps.couchplay.png" || true
rm -f "${PREFIX}/share/metainfo/io.github.hikaps.couchplay.metainfo.xml" || true

# Update desktop integration caches
if command -v gtk-update-icon-cache &>/dev/null; then
    gtk-update-icon-cache -f -t "${PREFIX}/share/icons/hicolor" 2>/dev/null || true
fi
if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "${PREFIX}/share/applications" 2>/dev/null || true
fi

# Clean up helper files manually (to guarantee clean removal even if install-helper.sh is missing)
rm -f "${LIBEXEC_DIR}/couchplay-helper" || true
rm -f "${DBUS_SYSTEM_DIR}/io.github.hikaps.CouchPlayHelper.conf" || true
rm -f "${DBUS_SERVICE_DIR}/io.github.hikaps.CouchPlayHelper.service" || true
rm -f "${SYSTEMD_DIR}/couchplay-helper.service" || true
rm -f "${POLKIT_DIR_USR}/io.github.hikaps.couchplay.policy" || true
rm -f "${POLKIT_DIR_ETC}/io.github.hikaps.couchplay.policy" || true
rm -f "${PREFIX}/share/pipewire/pipewire-pulse.conf.d/50-couchplay.conf" || true
rm -rf "${LIB_DIR}" || true

# =============================================================================
# Reload Daemons
# =============================================================================
print_info "Reloading systemd daemon-reload..."
systemctl daemon-reload || true

print_info "Reloading D-Bus configuration..."
if ! systemctl reload dbus 2>/dev/null; then
    # Fallback if systemctl reload dbus fails
    local pidfile dbus_pid
    for pidfile in /run/dbus/pid /var/run/dbus/pid; do
        if [[ -r "$pidfile" ]]; then
            dbus_pid="$(cat "$pidfile" 2>/dev/null || true)"
            if [[ -n "$dbus_pid" ]]; then
                kill -HUP "$dbus_pid" 2>/dev/null || true
            fi
        fi
    done
fi

# =============================================================================
# Steam Shortcuts and Artwork Cleanup
# =============================================================================
if command -v python3 &>/dev/null; then
    print_info "Cleaning up Steam shortcuts and custom artwork..."
    sudo -u "$REAL_USER" python3 - "$REAL_HOME" <<'EOF'
import os
import sys
import struct
import binascii
from pathlib import Path

def parse_vdf(data, pos=0):
    res = {}
    while pos < len(data):
        if pos >= len(data):
            break
        type_byte = data[pos]
        if type_byte == 8:
            return res, pos + 1
        pos += 1
        key_end = data.find(b'\x00', pos)
        if key_end == -1:
            break
        key = data[pos:key_end].decode('utf-8', errors='replace')
        pos = key_end + 1
        
        if type_byte == 0:
            val, pos = parse_vdf(data, pos)
            res[key] = val
        elif type_byte == 1:
            val_end = data.find(b'\x00', pos)
            if val_end == -1:
                break
            val = data[pos:val_end].decode('utf-8', errors='replace')
            pos = val_end + 1
            res[key] = val
        elif type_byte == 2:
            if pos + 4 > len(data):
                break
            val = struct.unpack('<I', data[pos:pos+4])[0]
            pos += 4
            res[key] = val
    return res, pos

def serialize_vdf(obj):
    res = bytearray()
    for key, val in obj.items():
        if isinstance(val, dict):
            res.append(0)
            res.extend(key.encode('utf-8') + b'\x00')
            res.extend(serialize_vdf(val))
        elif isinstance(val, str):
            res.append(1)
            res.extend(key.encode('utf-8') + b'\x00')
            res.extend(val.encode('utf-8') + b'\x00')
        elif isinstance(val, int):
            res.append(2)
            res.extend(key.encode('utf-8') + b'\x00')
            res.extend(struct.pack('<I', val))
    res.append(8)
    return res

def clean_shortcuts(vdf_path):
    vdf_path = Path(vdf_path)
    if not vdf_path.exists():
        return []
    
    try:
        with open(vdf_path, 'rb') as f:
            data = f.read()
    except Exception as e:
        print(f"Failed to read {vdf_path}: {e}", file=sys.stderr)
        return []
        
    if not data.startswith(b'\x00shortcuts\x00'):
        return []
        
    try:
        shortcuts, _ = parse_vdf(data, 11)
    except Exception as e:
        print(f"Failed to parse {vdf_path}: {e}", file=sys.stderr)
        return []
    
    new_shortcuts = {}
    idx = 0
    removed_appids = []
    modified = False
    
    # We sort keys numerically to preserve order
    keys = sorted(shortcuts.keys(), key=lambda x: int(x) if x.isdigit() else 999999)
    for k in keys:
        entry = shortcuts[k]
        if isinstance(entry, dict) and entry.get('appname') == 'CouchPlay':
            # Retrieve appid
            appid = entry.get('appid')
            if appid is not None:
                removed_appids.append(appid)
            modified = True
            continue
        new_shortcuts[str(idx)] = entry
        idx += 1
        
    if modified:
        new_data = b'\x00shortcuts\x00' + serialize_vdf(new_shortcuts)
        tmp_path = vdf_path.with_suffix('.tmp')
        try:
            with open(tmp_path, 'wb') as f:
                f.write(new_data)
            tmp_path.replace(vdf_path)
            print(f"Removed CouchPlay shortcut from {vdf_path}")
        except Exception as e:
            print(f"Error writing to {vdf_path}: {e}", file=sys.stderr)
            if tmp_path.exists():
                tmp_path.unlink()
                
    return removed_appids

def main():
    real_home = sys.argv[1] if len(sys.argv) > 1 else '/home/deck'
    possible_roots = [
        Path(real_home) / ".steam/steam/userdata",
        Path(real_home) / ".local/share/Steam/userdata",
        Path(real_home) / ".var/app/com.valvesoftware.Steam/.local/share/Steam/userdata"
    ]
    
    config_dirs = []
    for root in possible_roots:
        try:
            if root.is_dir():
                for d in root.iterdir():
                    if d.is_dir() and d.name.isdigit():
                        config_dir = d / "config"
                        if config_dir.is_dir():
                            config_dirs.append(config_dir)
        except Exception as e:
            # Ignore root access/permission issues
            pass
                        
    for cfg_dir in config_dirs:
        vdf_path = cfg_dir / "shortcuts.vdf"
        removed_ids = clean_shortcuts(vdf_path)
        
        grid_dir = cfg_dir / "grid"
        if grid_dir.is_dir() and removed_ids:
            for appid in removed_ids:
                try:
                    for f in grid_dir.glob(f"{appid}*"):
                        try:
                            f.unlink()
                            print(f"Removed custom artwork file: {f.name}")
                        except Exception as e:
                            print(f"Failed to remove {f}: {e}", file=sys.stderr)
                except Exception as e:
                    pass

if __name__ == '__main__':
    main()
EOF
else
    print_warn "python3 is not installed. Skipping Steam shortcuts and custom artwork cleanup."
fi

# =============================================================================
# Clean up Temporary Runtime Files
# =============================================================================
print_info "Cleaning up temporary CouchPlay runtime files..."
rm -rf /tmp/couchplay-sunshine-* || true
rm -rf /tmp/couchplay-* || true

# =============================================================================
# CouchPlay Player Users & Group Cleanup
# =============================================================================
if getent group couchplay >/dev/null; then
    members_str=$(getent group couchplay | cut -d: -f4)
    IFS=',' read -ra members <<< "$members_str"
    
    couchplay_users=()
    for u in "${members[@]}"; do
        if [[ -n "$u" && "$u" != "root" && "$u" != "$REAL_USER" ]]; then
            couchplay_users+=("$u")
        fi
    done
    
    if [[ ${#couchplay_users[@]} -gt 0 ]]; then
        print_warn "Found CouchPlay player accounts: ${couchplay_users[*]}"
        
        remove_users=false
        if [[ " $* " == *" --remove-users "* ]]; then
            remove_users=true
        elif [[ -t 0 ]]; then
            read -p "Would you like to delete these CouchPlay player accounts and their home directories? (y/n) [n]: " -r
            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                remove_users=true
            fi
        else
            print_info "Running non-interactively. Skipping player account deletion. Pass --remove-users to force removal."
        fi
        
        if $remove_users; then
            for u in "${couchplay_users[@]}"; do
                print_info "Deleting player user account: $u..."
                loginctl kill-user "$u" 2>/dev/null || true
                loginctl disable-linger "$u" 2>/dev/null || true
                sleep 0.5
                userdel -r "$u" 2>/dev/null || userdel -f "$u" 2>/dev/null || print_warn "Could not fully delete user account: $u"
            done
        fi
    fi
    
    print_info "Removing couchplay group..."
    groupdel couchplay 2>/dev/null || true
fi

# =============================================================================
# CouchPlay Configuration & Profile Data Cleanup
# =============================================================================
remove_data=false
if [[ " $* " == *" --remove-data "* ]]; then
    remove_data=true
elif [[ -t 0 ]]; then
    read -p "Would you like to delete CouchPlay configuration, profiles, and Flatpak data from your home directory? (y/n) [n]: " -r
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        remove_data=true
    fi
else
    print_info "Running non-interactively. Keeping configuration files. Pass --remove-data to delete configuration files."
fi

if $remove_data; then
    print_info "Removing CouchPlay configurations and data from ${REAL_HOME}..."
    rm -rf "$REAL_HOME/.local/share/couchplay" || true
    rm -rf "$REAL_HOME/.config/couchplay" || true
    rm -rf "$REAL_HOME/.config/io.github.hikaps.couchplay" || true
    rm -rf "$REAL_HOME/.var/app/io.github.hikaps.couchplay" || true
fi

echo ""
print_info "=========================================="
print_info "CouchPlay uninstalled successfully!"
print_info "=========================================="
echo ""
