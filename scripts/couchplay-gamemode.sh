#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2025 CouchPlay Contributors
#
# CouchPlay Game Mode Launcher
#
# Launches CouchPlay inside SteamOS Game Mode by starting a nested KWin Wayland
# compositor. This provides the org.kde.KWin D-Bus interface that CouchPlay's
# WindowManager requires for positioning gamescope windows side-by-side.
#
# Usage:
#   Add this script as a Non-Steam Game in Steam, or run it from a terminal:
#     ./couchplay-gamemode.sh
#
# How it works:
#   1. Detects whether we are inside SteamOS Game Mode (gamescope session).
#   2. Starts a nested kwin_wayland compositor that renders as a Wayland subsurface
#      inside the parent gamescope session.
#   3. Launches CouchPlay inside that nested compositor.
#   4. Controller isolation uses the D-Bus helper's driver unbind/rebind + temporary
#      udev rules to block the host Steam client from reading physical controllers.
#   5. On exit, kwin_wayland is terminated and controllers are automatically restored
#      by the D-Bus helper's ResetAllDevices().

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---

# CouchPlay binary: prefer build dir (development), then PATH, then /usr/local/bin
if [ -x "$SCRIPT_DIR/../build/bin/couchplay" ]; then
    COUCHPLAY_BIN="$SCRIPT_DIR/../build/bin/couchplay"
elif command -v couchplay &>/dev/null; then
    COUCHPLAY_BIN="$(command -v couchplay)"
elif [ -x /usr/local/bin/couchplay ]; then
    COUCHPLAY_BIN="/usr/local/bin/couchplay"
else
    echo "Error: CouchPlay binary not found."
    echo "Install CouchPlay or build it first."
    exit 1
fi

# Detect if running inside Flatpak sandbox
IS_FLATPAK=false
if [ -f /.flatpak-info ]; then
    IS_FLATPAK=true
fi

# --- Environment detection ---

is_game_mode() {
    # SteamOS Game Mode runs inside a gamescope session.
    # Check for the gamescope-specific env var or the session type.
    if [ "$IS_FLATPAK" = true ]; then
        # 1. Try checking the active session's Desktop via loginctl on the host
        local host_desktop=""
        host_desktop=$(flatpak-spawn --host sh -c 'loginctl show-session $(loginctl show-user $(id -un) | awk -F= "/^Display=/ {print \$2}") -p Desktop --value' 2>/dev/null) || true
        if [ "$host_desktop" = "gamescope" ]; then
            return 0
        fi

        # 2. Try checking if gamescope is in the host environment or running
        if flatpak-spawn --host sh -c 'env' | grep -qE "^(GAMESCOPE_WAYLAND_DISPLAY|SteamGamepadUI|XDG_CURRENT_DESKTOP=gamescope)="; then
            return 0
        fi

        if flatpak-spawn --host sh -c 'pgrep -x gamescope' &>/dev/null; then
            return 0
        fi

        return 1
    else
        if [ -n "${GAMESCOPE_WAYLAND_DISPLAY:-}" ]; then
            return 0
        fi
        # Alternative: check if the parent compositor is gamescope
        if [ -n "${SteamGamepadUI:-}" ] || [ "${XDG_CURRENT_DESKTOP:-}" = "gamescope" ]; then
            return 0
        fi
        return 1
    fi
}

# --- Cleanup ---

KWIN_PID=""

cleanup() {
    echo "CouchPlay Game Mode: Cleaning up..."
    if [ -n "$KWIN_PID" ] && kill -0 "$KWIN_PID" 2>/dev/null; then
        kill "$KWIN_PID" 2>/dev/null || true
        wait "$KWIN_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# --- Main ---

echo "CouchPlay Game Mode Launcher"
echo "============================="

if is_game_mode; then
    echo "Detected: SteamOS Game Mode (gamescope session)"
else
    echo "Detected: Desktop Mode"
    echo "Game Mode launcher is not required in Desktop Mode."
    echo "Launching CouchPlay directly..."
    exec "$COUCHPLAY_BIN" "$@"
fi

echo "Starting nested KWin Wayland compositor..."

SOCKET_NAME="wayland-couchplay"

if [ "$IS_FLATPAK" = true ]; then
    # KWin is bundled inside the Flatpak at /app/bin/kwin_wayland
    KWIN_BIN="/app/bin/kwin_wayland"
    if [ ! -f "$KWIN_BIN" ]; then
        echo "Error: Bundled kwin_wayland not found in Flatpak at $KWIN_BIN"
        exit 1
    fi
    # Force KWin to connect to the host's wayland-0 socket exposed in the sandbox
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
else
    if ! command -v kwin_wayland &>/dev/null; then
        echo "Error: kwin_wayland not found."
        echo "Install kwin_wayland (usually part of kwin or plasma-workspace)."
        exit 1
    fi
    KWIN_BIN="$(command -v kwin_wayland)"
fi

# Clean up any stale socket and lock files
rm -f "$XDG_RUNTIME_DIR/$SOCKET_NAME"
rm -f "$XDG_RUNTIME_DIR/${SOCKET_NAME}.lock"

# Kill any stale kwin_wayland process running inside the sandbox/session
pkill -f "kwin_wayland.*--socket.*$SOCKET_NAME" || true

# Define a persistent log file path inside the sandbox user settings (which maps to host user var folder)
LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/couchplay-kwin-wayland.log"
mkdir -p "$(dirname "$LOG_FILE")"
rm -f "$LOG_FILE"

# Start kwin_wayland directly in the background
# Under Flatpak, running KWin inside the sandbox ensures its PID is part of Steam's
# process tree and cgroup, allowing Gamescope to match and focus KWin's nested window.
export QT_FORCE_STDERR_LOGGING=1
"$KWIN_BIN" \
    --desktopfile io.github.hikaps.couchplay \
    --no-lockscreen \
    --no-global-shortcuts \
    --width "${GAMESCOPE_WIDTH:-1920}" \
    --height "${GAMESCOPE_HEIGHT:-1080}" \
    --socket "$SOCKET_NAME" \
    > "$LOG_FILE" 2>&1 &

KWIN_PID=$!

# Wait for the new Wayland socket to appear in XDG_RUNTIME_DIR (up to 10 seconds)
echo "Waiting for nested KWin Wayland socket..."
SOCKET_FOUND=false
for i in $(seq 1 20); do
    if [ -S "$XDG_RUNTIME_DIR/$SOCKET_NAME" ]; then
        SOCKET_FOUND=true
        break
    fi
    sleep 0.5
done

if [ "$SOCKET_FOUND" = true ]; then
    echo "Found nested KWin Wayland socket: $SOCKET_NAME"
    export WAYLAND_DISPLAY="$SOCKET_NAME"
else
    echo "Warning: Nested KWin Wayland socket not found. Falling back to default."
    if [ "$IS_FLATPAK" = true ]; then
        echo "kwin_wayland log ($LOG_FILE):"
        tail -n 20 "$LOG_FILE" || true
    fi
fi

# Wait for KWin to register on D-Bus (up to 10 seconds)
echo "Waiting for KWin D-Bus interface..."
KWIN_READY=false
for i in $(seq 1 20); do
    if dbus-send --session --dest=org.kde.KWin --print-reply \
        /KWin org.kde.KWin.currentDesktop &>/dev/null 2>&1; then
        KWIN_READY=true
        break
    fi
    sleep 0.5
done

if [ "$KWIN_READY" = false ]; then
    echo "Error: KWin did not start within 10 seconds."
    echo "Check that kwin_wayland is installed and working."
    exit 1
fi

echo "KWin is ready (PID: $KWIN_PID)"
echo "Launching CouchPlay..."

# Set environment so CouchPlay connects to the nested KWin's Wayland display
# WAYLAND_DISPLAY is inherited from kwin_wayland's nested output
export QT_QPA_PLATFORM=wayland

# Enable CouchPlay debug logging for troubleshooting
export QT_LOGGING_RULES="couchplay.*=true"
export QT_MESSAGE_PATTERN="[%{time hh:mm:ss.zzz}] %{if-category}%{category}: %{endif}%{message}"

# Launch CouchPlay, blocking until it exits
GUI_LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/couchplay-gui.log"
echo "CouchPlay GUI output is being logged to: $GUI_LOG_FILE"
"$COUCHPLAY_BIN" "$@" > "$GUI_LOG_FILE" 2>&1
COUCHPLAY_EXIT=$?

echo "CouchPlay exited with code $COUCHPLAY_EXIT"
exit $COUCHPLAY_EXIT
