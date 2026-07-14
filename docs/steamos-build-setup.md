# SteamOS Native Build & Development Setup Guide

This guide describes how to configure your SteamOS environment, install the necessary compilation dependencies, build CouchPlay from source, and package/deploy it for testing. 

SteamOS is an immutable distribution with a read-only root filesystem (`/`) by default. To compile CouchPlay natively, you must temporarily disable the read-only lock to install system headers and compiler tools, run the build process, and then restore the system to its clean state.

---

## Quick Start (Automated Setup)

To quickly prepare your development environment and install all dependencies:
```bash
./scripts/steamos-setup-dev.sh
```

When you are done compiling and want to lock the filesystem again:
```bash
./scripts/steamos-teardown-dev.sh
```

---

## Manual Step-by-Step Setup

If you prefer to run the commands individually, follow the steps below.

### 1. Preparing the SteamOS Environment

Before installing development packages, you must enable write access to the root partition and initialize the pacman package manager's keyring.

#### Step 1: Check if running on SteamOS
Confirm you are running on SteamOS:
```bash
grep -q "ID=steamos" /etc/os-release && echo "Confirmed: Running on SteamOS"
```

#### Step 2: Disable Read-Only Mode & Stop System Extensions
Disable read-only enforcement and temporarily stop system extensions (`systemd-sysext`) to prevent file conflicts:
```bash
sudo steamos-readonly disable
sudo systemctl stop systemd-sysext
```

#### Step 3: Initialize and Populate Pacman Keys
Initialize the Arch Linux and Holo keyrings so you can securely retrieve packages:
```bash
sudo pacman-key --init
sudo pacman-key --populate archlinux
sudo pacman-key --populate holo
```

---

### 2. Installing Build Dependencies

Install the compilers, build tools, development libraries, and header packages required by CouchPlay:

```bash
echo "


" | sudo pacman -S base-devel cmake qt6-base ninja extra-cmake-modules qt6-tools qt6-declarative libglvnd mesa kf6 qqc2-desktop-style kglobalaccel kirigami gcc-libs openmp vulkan-headers glibc polkit-qt6 linux-api-headers
```

> [!NOTE]
> The empty newlines piped into `pacman` are used to auto-confirm any interactive prompts (such as choosing package provider alternatives or confirming re-installations).

---

## 3. Cloning & Building CouchPlay

Now that the compiler toolchain and dependencies are available, you can build CouchPlay:

### Step 1: Clone the Repository (or pull latest)
```bash
cd ~/Documents
if [[ -d couchplay ]]; then
    cd couchplay
    git pull
else
    git clone https://github.com/hikaps/couchplay.git
    cd couchplay
fi
```

### Step 2: Configure & Compile
Clean any existing build artifacts, configure with CMake, and build the binaries:
```bash
rm -rf CMakeCache.txt CMakeFiles/ build/
cmake -B build
cmake --build build
```

---

## 4. Re-enabling Read-Only Mode & Restoring the System

To ensure system integrity, always re-enable read-only mode after compiling:

```bash
sudo steamos-readonly enable
```

> [!TIP]
> Any package files installed into `/usr/` or other root folders during this setup will be naturally discarded when SteamOS performs a system update. This ensures your OS remains clean and unmodified. 
>
> The easiest way to manage this is via the teardown script:
> ```bash
> ./scripts/steamos-teardown-dev.sh
> ```
> This script will query the currently tracked update branch (e.g. `stable` or `beta`), prompt you to switch to the opposing branch, and optionally run `steamos-update` and reboot the system to restore the stock filesystem immediately.
> 
> Because the script is idempotent, **you can run it again after rebooting** to easily switch the update branch back.

---

## 5. Local Packaging and User-space Deployment

Once compiled, you can package the local GUI into a Flatpak and load the helper service as a system extension using the user-space updater script.

Every time you build a new version of the application, run:
```bash
./scripts/update-nonroot.sh
```

This non-root script will:
1. Verify the locally built helper binary exists at `build/bin/couchplay-helper`.
2. Build and install the Flatpak application locally (overriding the Git sources with your local directory).
3. Build a fresh system extension raw image (`~/.couchplay.steamos.raw`) from your built helper binary.

### Applying System Extension Changes
After `update-nonroot.sh` finishes, reload and restart the helper service by running the following commands (requires root/sudo):
```bash
sudo systemd-sysext refresh
sudo systemctl daemon-reload
sudo systemctl restart couchplay-helper.service
```
