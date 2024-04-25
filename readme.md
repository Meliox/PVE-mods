# Proxmox mods and scripts
A small collection of script and mods for Proxmox

If you find this helpful, a small donation is appreciated, [![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K8XPMSEBERH3W).

## Node temperature view
(Tested compatibility: 7.x, 8.0.x, 8.1.x, 8.2.x)

This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display temperature information in a flexible manner for CPU, NVME and HDDs/SSDs. Fanspeeds are also displayed, if available.

The modification includes three main steps:

1. Create backups of the original files located at `/usr/share/pve-manager/js/pvemanagerlib.js` and `/usr/share/perl5/PVE/API2/Nodes.pm` in the `/root/backup` directory.
2. Add a new line to the `Nodes.pm` file that reads the thermal state information of the host using the `sensors` command.
3. Modify the `pvemanagerlib.js` file to expand the space in the StatusView and add a new item to the items array that displays the temperature information in Celsius for CPU, NVME and HDDs/SSDs.

The script provides two options: `install` and `uninstall`. The `install` option installs the modification, while the `uninstall` option removes it by copying the backup files to their original location. The script also restarts the `pveproxy` service to apply the changes.

For HDDs/SSDs readings to work, the kernal module drivetemp must be installed.

### Install
```
apt-get install lm-sensors
wget https://raw.githubusercontent.com/Meliox/PVE-mods/main/pve-mod-gui-temp.sh
```
Or use git clone.

![Promxox temp mod](https://github.com/Meliox/PVE-mods/blob/main/pve-mod-temp.png?raw=true)

Adjustments are available in the first part of the script, where paths can be edited, cpucore offset and display information.

## Nag screen deactivation
(Tested compatibility: 7.x, 8.0.x, 8.1.x, 8.2.x)
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
