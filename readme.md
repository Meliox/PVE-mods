# Proxmox Virtual Environment mods and scripts
A small collection of scripts and mods for Proxmox Virtual Environment (PVE)

If you find this helpful, a small donation is appreciated, [![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K8XPMSEBERH3W).

## Node sensor readings view
(Tested compatibility: 7.x - 8.2)

This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display sensor readings in a flexible and readable manner. Supported are CPU, NVMe/HDD/SSD temperatures and fan speeds.

The modification includes three main steps:

1. Create backups of the original files located at `/usr/share/pve-manager/js/pvemanagerlib.js` and `/usr/share/perl5/PVE/API2/Nodes.pm` in the `backup` directory relative to the script location.
2. Add a new code to the `Nodes.pm` file that enables host system sensor readings using the `sensors` command.
3. Modify the `pvemanagerlib.js` file to expand the space in the node status view, add new items that display the temperature information in Celsius for CPUs, NVMe drives, HDDs/SSDs and fan speeds (the actual item list depends on the sensor readings available during the installation). The view layout is also adjusted to no longer match the column number setting and always expands to the full width of the browser window. It is also possible to collapse the panel vertically.

The script provides two options: `install` and `uninstall`. The `install` option installs the modification, while the `uninstall` option removes it by copying the backup files to their original location. The script also restarts the `pveproxy` service to apply the changes.

For HDDs/SSDs readings to work, the kernel module *drivetemp* must be installed.

### Install
```
apt-get install lm-sensors
wget https://raw.githubusercontent.com/Meliox/PVE-mods/main/pve-mod-gui-sensors.sh
bash pve-mod-gui-sensors.sh
```
Or use git clone.
Then clear the browser cache to ensure all changes are visualized.

![Promxox temp mod](https://github.com/Meliox/PVE-mods/blob/main/pve-mod-sensors.png?raw=true)

Adjustments are available in the first part of the script, where paths can be edited, cpucore offset and display information.

## Nag screen deactivation
(Tested compatibility: 7.x - 8.2)
This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) which deactivates the subscription nag screen.

The script provides two options: `install` and `uninstall`. The `install` option installs the modification, while the `uninstall` option removes it by copying the backup files to their original location.

### Install
```
wget https://raw.githubusercontent.com/Meliox/PVE-mods/main/pve-mod-nag-screen.sh
```
Or use git clone.

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
