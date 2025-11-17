# AI Small Infrastructure Accelerator (AISIA)

A lightweight, modular toolkit for deploying small, self-contained AI
infrastructure---optimized for **Podman Quadlets**, **GPU
acceleration**, and **local-first AI workflows**.

AISIA helps you deploy AI tools such as **ComfyUI**, **SDG Hub**,
**InstructLab**, and others using **simple, persistent, restart-safe
Quadlet services**.

## 📦 Repository Structure

    ai-small-infrastructure-accelerator-AISIA/
    ├── quadlets/                 # Quadlet definitions for user-space systemd services
    │   ├── comfyui.container
    │   ├── sdg-hub-ui.container
    │   └── ...
    ├── scripts/                  # Deployment helpers (install, enable, reload, etc.)
    │   ├── deploy_quadlet.sh
    │   └── uninstall_quadlet.sh
    ├── external-resources/       # Container images that must be built locally
    │   └── comfyUI/
    │       ├── Containerfile
    │       └── assets/...
    └── README.md                 # This file

## 🚀 Features

### ✔ Quadlet-based Container Services

All AI tools run as **systemd user services**, giving you:

-   Automatic restarts\
-   Persistent storage\
-   GPU access via CDI/Podman\
-   Clean logs via `journalctl --user`\
-   Seamless updates by replacing the `.container` file

### ✔ Selective Tool Deployment

The `deploy_quadlet.sh` script lets you:

-   Choose exactly which tools to deploy\
-   Install quadlets into `~/.config/containers/systemd/`\
-   Enable lingering for background execution\
-   Reload user systemd and start services immediately

### ✔ GPU-Ready (NVIDIA / AMD / Intel)

Uses Podman CDI interface:

    AddDevice=nvidia.com/gpu=all

## 🛠 Requirements

  Component                       Version    Notes
  ------------------------------- ---------- ---------------------------------
  Fedora / RHEL / CentOS Stream   Latest     Tested on Fedora 42
  Podman                          5.6+       Quadlet v2 supported
  Systemd (user mode)             Required   Quadlet auto-generation
  GPU Drivers                     Optional   NVIDIA CDI works out-of-the-box

## 📁 External Resources (Local Image Builds Required)

Some containers **cannot be pulled** from registries and must be built
manually.

    external-resources/

Currently, only **ComfyUI** is a local-build image.

##  1. Build Local Image (One-Time Setup)

### Step 1 --- Navigate to the ComfyUI build directory

``` bash
cd ai-small-infrastructure-accelerator-AISIA/external-resources/comfyUI
```

### Step 2 --- Build the ComfyUI image

``` bash
podman build -t local/comfyui:latest .
```

### Step 3 --- Verify

``` bash
podman images | grep comfy
```

Ensure quadlet uses:

    Image=local/comfyui:latest

## ⚙️ 2. Deploy Quadlets

``` bash
./scripts/deploy_quadlet.sh
```

## 🔍 3. Check Service Status

``` bash
systemctl --user list-units | grep aisia
systemctl --user status comfyui.service
journalctl --user -u comfyui -f
```

## 📂 4. Persistent Data Locations

  Tool          Path
  ------------- -----------------------------
  ComfyUI       `~/aisia-data/comfyui/`

Fix SELinux if needed:

``` bash
sudo chcon -Rt container_file_t ~/aisia-data
```

## ♻️ 5. Updating Quadlets

``` bash
systemctl --user daemon-reload
systemctl --user restart <service>.service
```

## 🧹 6. Uninstall Tools

``` bash
./scripts/uninstall_quadlet.sh
```

## 📜 License

MIT License

