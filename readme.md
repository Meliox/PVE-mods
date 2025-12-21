# Proxmox Virtual Environment mods and scripts
A small collection of scripts and mods for Proxmox Virtual Environment (PVE)

If you find this helpful, a small donation is appreciated, [![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K8XPMSEBERH3W).

## Node sensor readings view
(Tested compatibility: 9.x. Using older version (7.x-8.x), use git version from Apr 6th 2025)
![Promxox temp mod](https://github.com/Meliox/PVE-mods/blob/main/pve-mod-sensors.png?raw=true)

This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display sensor readings in a flexible and readable manner.
The following readings are possible:
- CPU, NVMe/HDD/SSD temperatures (Celsius/Fahrenheit), fan speeds, ram temperatures via lm-sensors. Note: Hdds require kernel module *drivetemp* module installed.
- UPS information via Network Monitoring Tool
- Motherboard information or system information via dmidecode

### How it works
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

### Install
Instructions be performed as 'root', as normal users do not have access to the files.

```
apt-get install lm-sensors
# lm-sensors must be configured, run below to configure your sensors, apply temperature offsets. Refer to lm-sensors manual for more information.
sensors-detect 
wget https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/pve-mod-gui-sensors.sh
bash pve-mod-gui-sensors.sh install
# Then clear the browser cache to ensure all changes are visualized.
```
Additionally, adjustments are available in the first part of the script, where paths can be edited, cpucore offset and display information.

## NVIDIA GPU readings view
![Proxmox NVIDIA GPU mod](pve-mod-nvidia.png)

This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display NVIDIA GPU information in the node status view.

The following readings are displayed (per GPU):
- GPU name and index
- Temperature (Celsius/Fahrenheit)
- GPU utilization
- Memory utilization, used/total
- Power draw / power limit
- Fan speed (if supported)

### How it works
The modification involves the following steps:
1. Backup original files in a backup directory (default: `~/PVE-MODS`, configurable via `BACKUP_DIR` in the script)
   - `/usr/share/pve-manager/js/pvemanagerlib.js`
   - `/usr/share/perl5/PVE/API2/Nodes.pm`
2. Patch `Nodes.pm` to add an API field (`nvidiaGpuOutput`) populated by `nvidia-smi`.
3. Modify `pvemanagerlib.js` to insert a new StatusView widget (“NVIDIA GPU Status”) before the CPU widget.
4. Restart the `pveproxy` service to apply changes.

The script provides two options:
| **Option**   | **Description** |
|-------------|------------------|
| `install`   | Apply the modification. |
| `uninstall` | Restore original files from backups (see note below). |

Notes:
- Requires NVIDIA drivers installed on the Proxmox host (`nvidia-smi` must be available).
- If you have other PVE UI mods installed (e.g. the sensors UI mod), uninstalling via backup restore may revert other changes depending on backup order. The script will warn if it detects other mods.
- Proxmox upgrades may overwrite modified files; reinstallation of this mod could be required.

### Install
Instructions be performed as 'root', as normal users do not have access to the files.

```
# Ensure NVIDIA drivers are installed and nvidia-smi works.
# (Example check)
nvidia-smi

wget https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/pve-mod-gui-nvidia.sh
bash pve-mod-gui-nvidia.sh install
# Then clear the browser cache to ensure all changes are visualized.
```

## Nag screen deactivation
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

### Install
Instructions be performed as 'root', as normal users do not have access to the files.
```
wget https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/pve-mod-nag-screen.sh
bash pve-mod-nag-screen.sh install
```

## Script to update all containers
(Tested compatibility: 7.x - 8.3.5)

This script updates all running Proxmox containers, skipping specified excluded containers, and generates a separate log file for each container.
The script first updates the Proxmox host system, then iterates through each container, updates the container, and reboots it if necessary.
Each container's log file is stored in $log_path and the main script log file is named container-upgrade-main.log.

### Install
```
wget https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/updateallcontainers.sh
```
Or use git clone.
Can be added to cron for e.g. monthly update: ```0 6 1 * * /root/scripts/updateallcontainers.sh```
