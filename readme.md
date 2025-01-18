# Proxmox Virtual Environment mods and scripts
A small collection of scripts and mods for Proxmox Virtual Environment (PVE)

If you find this helpful, a small donation is appreciated, [![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K8XPMSEBERH3W).

## Node sensor readings view
(Tested compatibility: 7.x - 8.2)
![Promxox temp mod](https://github.com/Meliox/PVE-mods/blob/main/pve-mod-sensors.png?raw=true)

This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display sensor readings in a flexible and readable manner. Supported are CPU, NVMe/HDD/SSD temperatures (Celsius/Fahrenheit), fan speeds and ram temperatures.

The modification includes three main steps:

1. Create backups of the original files located at `/usr/share/pve-manager/js/pvemanagerlib.js` and `/usr/share/perl5/PVE/API2/Nodes.pm` in the the `backup` directory relative to the script location.
2. Add a new code to the `Nodes.pm` file that enables host system sensor readings using the `sensors` command.
3. Modify the `pvemanagerlib.js` file to expand the space in the node status view, add new items that display the temperature information in Celsius for CPUs, NVMe drives, HDDs/SSDs and fan speeds (the actual item list depends on the sensor readings available during the installation). The view layout is also adjusted to no longer match the column number setting and always expands to the full width of the browser window. It is also possible to collapse the panel vertically.
4. Finally, the script also restarts the `pveproxy` service to apply the changes.

The script provides three options:
| **Option**             | **Description**                                                             |
|-------------------------|-----------------------------------------------------------------------------|
| `install`              | Installs the modification by applying the necessary changes.                |
| `uninstall`            | Removes the modification by restoring the original files from backups.      |
| `save-sensors-data`    | Saves a local copy of your sensor data for reference or backup.             |

Note:
For HDDs/SSDs readings to work, the kernel module *drivetemp* must be installed.

### Install
Instructions be performed as 'root', as normal users do not have access to the files.

```
apt-get install lm-sensors
# lm-sensors need configure, run below to configure your sensors, or refer to lm-sensors manual.
sensors-detect 
wget https://raw.githubusercontent.com/Meliox/PVE-mods/main/pve-mod-gui-sensors.sh
bash pve-mod-gui-sensors.sh install
# Then clear the browser cache to ensure all changes are visualized.
```
Additionally, adjustments are available in the first part of the script, where paths can be edited, cpucore offset and display information.

## Nag screen deactivation
(Tested compatibility: 7.x - 8.2)
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
wget https://raw.githubusercontent.com/Meliox/PVE-mods/main/pve-mod-nag-screen.sh
bash pve-mod-nag-screen.sh install
```

## Script to update all containers
(Tested compatibility: 7.x & 8.0)

This script updates all running Proxmox containers, skipping specified excluded containers, and generates a separate log file for each container.
The script first updates the Proxmox host system, then iterates through each container, updates the container, and reboots it if necessary.
Each container's log file is stored in $log_path and the main script log file is named container-upgrade-main.log.

### Install
```
wget https://raw.githubusercontent.com/Meliox/PVE-mods/main/updateallcontainers.sh
```
Or use git clone.
Can be added to cron for e.g. monthly update: ```0 6 1 * * /root/scripts/updateallcontainers.sh```
