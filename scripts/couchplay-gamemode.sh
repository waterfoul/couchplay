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
    if [ -n "${GAMESCOPE_WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi
    # Alternative: check if the parent compositor is gamescope
    if [ -n "${SteamGamepadUI:-}" ] || [ "${XDG_CURRENT_DESKTOP:-}" = "gamescope" ]; then
        return 0
    fi
    return 1
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

# Clean up any stale socket
rm -f "$XDG_RUNTIME_DIR/$SOCKET_NAME"

# Start kwin_wayland as a nested compositor inside gamescope.
# Only reached in Game Mode — kwin_wayland check is deferred to here
# so Desktop Mode launches never fail due to a missing kwin_wayland.
if [ "$IS_FLATPAK" = true ]; then
    # When sandboxed, run kwin_wayland on the host via flatpak-spawn. The socket
    # is placed inside the Flatpak app's XDG_RUNTIME_DIR subdirectory so it is
    # accessible from inside the sandbox.
    if ! flatpak-spawn --host sh -c "command -v kwin_wayland" &>/dev/null; then
        echo "Error: kwin_wayland not found on host."
        echo "Please install kwin_wayland on the host system."
        exit 1
    fi
    flatpak-spawn --host kwin_wayland \
        --no-lockscreen \
        --no-global-shortcuts \
        --width "${GAMESCOPE_WIDTH:-1920}" \
        --height "${GAMESCOPE_HEIGHT:-1080}" \
        --socket "app/io.github.hikaps.couchplay/$SOCKET_NAME" \
        &
else
    if ! command -v kwin_wayland &>/dev/null; then
        echo "Error: kwin_wayland not found."
        echo "Install kwin_wayland (usually part of kwin or plasma-workspace)."
        exit 1
    fi
    KWIN_BIN="$(command -v kwin_wayland)"
    "$KWIN_BIN" \
        --no-lockscreen \
        --no-global-shortcuts \
        --width "${GAMESCOPE_WIDTH:-1920}" \
        --height "${GAMESCOPE_HEIGHT:-1080}" \
        --socket "$SOCKET_NAME" \
        &
fi

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
"$COUCHPLAY_BIN" "$@"
COUCHPLAY_EXIT=$?

echo "CouchPlay exited with code $COUCHPLAY_EXIT"
exit $COUCHPLAY_EXIT
