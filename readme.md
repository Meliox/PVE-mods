# Proxmox Virtual Environment mods and scripts
A small collection of scripts and mods for Proxmox Virtual Environment (PVE)

If you find this helpful, a small donation is appreciated, [![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K8XPMSEBERH3W).

| Version | Description | Status |
|---------|-------------|--------|
| **v2** (current) | Debian package (`pve-mod`) with interactive `pve-mod-configure` wizard | Recommended |
| v1 (legacy) | Standalone bash scripts, manual install | Archived — see [Legacy section](#legacy-v1-shell-scripts) |

---

## Version 2 — Debian package

Compatibility: PVE 9.0+

![Proxmox temp mod](https://github.com/Meliox/PVE-mods/blob/main/pve-mod-sensors.png?raw=true)

`pve-mod` is a proper Debian package that installs UI patches, a background sensor daemon, and an interactive configuration wizard. It replaces the legacy standalone scripts with a structured, maintainable approach.

### Modules

| Module | Description |
|--------|-------------|
| `node_info` | Displays sensor readings in the node status panel: CPU, NVMe/HDD/SSD temperatures (°C/°F), fan speeds, RAM temperatures, GPU stats (Intel/NVIDIA), UPS status, and system/motherboard info. GPU historical graphs are optionally available. |
| `nag_screen` | Removes the subscription nag screen from the PVE web UI. |

### How it works

1. The `pve-mod` package installs patch files, a Perl sensor module, and helper scripts under `/usr/lib/pve-mod/`.
2. Running `pve-mod-configure` detects installed hardware (via `lm-sensors`, `nvidia-smi`, `intel_gpu_top`, etc.), prompts for which features to enable, and writes configuration to `/etc/pve-mod/pve-mod.conf` and `/etc/pve-mod/conf.d/`.
3. The wizard then applies the selected patches to the PVE system files and restarts `pveproxy`.
4. Optionally, a dpkg trigger can be enabled to automatically re-apply patches after every `pve-manager` upgrade.

### Install

Must be run as `root`.

```bash
curl -sL https://github.com/Meliox/PVE-mods/releases/latest/download/install.sh | bash
pve-mod-configure
# Then clear the browser cache to ensure all changes are visualized.
```

`pve-mod-configure` can be re-run at any time to change settings or enable/disable modules.

### Notes

- `lm-sensors` must be configured before running `pve-mod-configure`. Run `sensors-detect` and load the suggested kernel modules first.
- HDDs require the `drivetemp` kernel module to report temperatures.
- UPS monitoring requires `nut-client` (`upsc`).
- Intel GPU monitoring requires `intel-gpu-tools`.
- NVIDIA GPU monitoring requires NVIDIA drivers with `nvidia-smi`.
- UPS support in multi-node setups requires identical login credentials across nodes.

---

## Legacy / v1 (shell scripts)

> **These scripts are archived.** For new installations, use the [v2 Debian package](#version-2--debian-package) above.

### Node sensor readings view

Compatibility:
- 9.0-9.2. Newer versions may often work
- Older version (7.x-8.x), use git version from Apr 6th 2025

This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display sensor readings in a flexible and readable manner.
The following readings are possible:
- CPU, NVMe/HDD/SSD temperatures (Celsius/Fahrenheit), fan speeds, ram temperatures via lm-sensors. Note: Hdds require kernel module *drivetemp* module installed.
- UPS information via Network Monitoring Tool
- Motherboard information or system information via dmidecode

#### How it works
The modification involves the following steps:
1. Backup original files in the home directory/backup
   - `/usr/share/pve-manager/js/pvemanagerlib.js`
   - `/usr/share/perl5/PVE/API2/Nodes.pm`   
2. Patch `Nodes.pm` to enable readings.  
3. Modify `pvemanagerlib.js` to:  
   - Expand the node status view to full browser width.  
   - Add reading (depending on  & selections).  
   - Allow collapsing the panel vertically.  
4. Restart the `pveproxy` service to apply changes.

The script provides three options:
| **Option**             | **Description**                                                             |
|-------------------------|-----------------------------------------------------------------------------|
| `install`              | Apply the modification.                |
| `uninstall`            | Restore original files from backups.      |
| `save-sensors-data`    | Save a local copy of detected sensor data for reference or troubleshooting.             |

Notes:
- UPS support in multi-node setups require identical login credentials across nodes. This has not been fully tested.  
- Proxmox upgrades may overwrite modified files; reinstallation of this mod could be required.  

#### Install
Instructions be performed as 'root', as normal users do not have access to the files.

```
apt-get install lm-sensors
# lm-sensors must be configured, run below to configure your sensors, apply temperature offsets. Refer to lm-sensors manual for more information.
sensors-detect 
wget https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/legacy-scripts/pve-mod-gui-sensors.sh
bash pve-mod-gui-sensors.sh install
# Then clear the browser cache to ensure all changes are visualized.
```
Additionally, adjustments are available in the first part of the script, where paths can be edited, cpucore offset and display information.

### Nag screen deactivation
(Tested compatibility: 7.x - 8.3.5)
This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) which deactivates the subscription nag screen.

The modification includes two main steps:
1. Create backups of the original files in the `backup` directory relative to the script location.
2. Modify code.

The script provides three options:
| **Option**             | **Description**                                                             |
|-------------------------|-----------------------------------------------------------------------------|
| `install`              | Installs the modification by applying the necessary changes.                |
| `uninstall`            | Removes the modification by restoring the original files from backups.      |

#### Install
Instructions be performed as 'root', as normal users do not have access to the files.
```
wget https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/legacy-scripts/pve-mod-nag-screen.sh
bash pve-mod-nag-screen.sh install
```

### Script to update all containers
(Tested compatibility: 7.x - 8.3.5)

This script updates all running Proxmox containers, skipping specified excluded containers, and generates a separate log file for each container.
The script first updates the Proxmox host system, then iterates through each container, updates the container, and reboots it if necessary.
Each container's log file is stored in $log_path and the main script log file is named container-upgrade-main.log.

#### Install
```
wget https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/legacy-scripts/updateallcontainers.sh
```
Or use git clone.
Can be added to cron for e.g. monthly update: ```0 6 1 * * /root/scripts/updateallcontainers.sh```
