#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2025 CouchPlay Contributors
#
# CouchPlay Game Mode Launcher
#
# Launches CouchPlay inside SteamOS Game Mode by starting a nested KWin Wayland
# compositor. This runs natively on the host system to ensure correct process tree
# and cgroup tracking by Steam and Gamescope.
#
# Usage:
#   Add this script as a Non-Steam Game in Steam, or run it from a terminal:
#     ./couchplay-gamemode.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve CouchPlay run command
RUN_COMMAND=""
if [ -x "$SCRIPT_DIR/../build/bin/couchplay" ]; then
    RUN_COMMAND="$SCRIPT_DIR/../build/bin/couchplay"
elif flatpak list --columns=application | grep -q "^io.github.hikaps.couchplay$"; then
    RUN_COMMAND="flatpak run"
elif command -v couchplay &>/dev/null; then
    RUN_COMMAND="$(command -v couchplay)"
elif [ -x /usr/local/bin/couchplay ]; then
    RUN_COMMAND="/usr/local/bin/couchplay"
else
    echo "Error: CouchPlay not found (neither local build, flatpak package, nor system binary found)."
    exit 1
fi

is_game_mode() {
    # Check if running under gamescope (SteamOS Game Mode)
    [ -n "${GAMESCOPE_WAYLAND_DISPLAY:-}" ]
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
    if [ "$RUN_COMMAND" = "flatpak run" ]; then
        exec flatpak run io.github.hikaps.couchplay "$@"
    else
        exec $RUN_COMMAND "$@"
    fi
fi

echo "Starting nested KWin Wayland compositor on host..."

SOCKET_NAME="wayland-couchplay"

if [ "$RUN_COMMAND" = "flatpak run" ]; then
    SOCKET_PATH="app/io.github.hikaps.couchplay/$SOCKET_NAME"
else
    SOCKET_PATH="$SOCKET_NAME"
fi

# Ensure target socket directory exists
mkdir -p "$(dirname "$XDG_RUNTIME_DIR/$SOCKET_PATH")"

# Clean up any stale socket and lock files
rm -f "$XDG_RUNTIME_DIR/$SOCKET_PATH"
rm -f "$XDG_RUNTIME_DIR/${SOCKET_PATH}.lock"

# Kill any stale kwin_wayland process running on the host
pkill -f "kwin_wayland.*--socket.*$SOCKET_NAME" || true

if ! command -v kwin_wayland &>/dev/null; then
    echo "Error: kwin_wayland not found."
    echo "Install kwin_wayland (usually part of kwin or plasma-workspace)."
    exit 1
fi
KWIN_BIN="$(command -v kwin_wayland)"

# Define a persistent log file path
LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/couchplay-kwin-wayland.log"
mkdir -p "$(dirname "$LOG_FILE")"
rm -f "$LOG_FILE"

# Start kwin_wayland directly on the host in the background
# This puts KWin directly inside the host process tree launched by Steam,
# allowing Gamescope to match and focus KWin's nested window instantly.
export QT_FORCE_STDERR_LOGGING=1
"$KWIN_BIN" \
    --desktopfile io.github.hikaps.couchplay \
    --no-lockscreen \
    --no-global-shortcuts \
    --width "${GAMESCOPE_WIDTH:-1920}" \
    --height "${GAMESCOPE_HEIGHT:-1080}" \
    --socket "$SOCKET_PATH" \
    > "$LOG_FILE" 2>&1 &

KWIN_PID=$!

# Wait for the new Wayland socket to appear in XDG_RUNTIME_DIR (up to 10 seconds)
echo "Waiting for nested KWin Wayland socket..."
SOCKET_FOUND=false
for i in $(seq 1 20); do
    if [ -S "$XDG_RUNTIME_DIR/$SOCKET_PATH" ]; then
        SOCKET_FOUND=true
        break
    fi
    sleep 0.5
done

if [ "$SOCKET_FOUND" = true ]; then
    echo "Found nested KWin Wayland socket: $SOCKET_PATH"
else
    echo "Warning: Nested KWin Wayland socket not found. Falling back to default."
    echo "kwin_wayland log ($LOG_FILE):"
    tail -n 20 "$LOG_FILE" || true
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

# Enable CouchPlay debug logging for troubleshooting
export QT_LOGGING_RULES="couchplay.*=true"
export QT_MESSAGE_PATTERN="[%{time hh:mm:ss.zzz}] %{if-category}%{category}: %{endif}%{message}"

# Launch CouchPlay, blocking until it exits
GUI_LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/couchplay-gui.log"
echo "CouchPlay GUI output is being logged to: $GUI_LOG_FILE"

if [ "$RUN_COMMAND" = "flatpak run" ]; then
    exec flatpak run \
        --env=WAYLAND_DISPLAY="$SOCKET_PATH" \
        --env=QT_QPA_PLATFORM=wayland \
        --env=QT_LOGGING_RULES="$QT_LOGGING_RULES" \
        --env=QT_MESSAGE_PATTERN="$QT_MESSAGE_PATTERN" \
        io.github.hikaps.couchplay "$@" > "$GUI_LOG_FILE" 2>&1
else
    export WAYLAND_DISPLAY="$SOCKET_PATH"
    export QT_QPA_PLATFORM=wayland
    exec "$RUN_COMMAND" "$@" > "$GUI_LOG_FILE" 2>&1
fi
