# Proxmox mods and script
A small collection of script and mods for Proxmox

## Node temperature view
(Test compatibility against 7.x & 8.0)

This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display temperature information in a flexible manner for CPU, NVME and HDDs/SSDs.

The modification includes three main steps:

1. Create backups of the original files located at `/usr/share/pve-manager/js/pvemanagerlib.js` and `/usr/share/perl5/PVE/API2/Nodes.pm` in the `/root/backup` directory.
2. Add a new line to the `Nodes.pm` file that reads the thermal state information of the host using the `sensors` command.
3. Modify the `pvemanagerlib.js` file to expand the space in the StatusView and add a new item to the items array that displays the temperature information in Celsius for CPU, NVME and HDDs/SSDs.

The script provides two options: `install` and `uninstall`. The `install` option installs the modification, while the `uninstall` option removes it by copying the backup files to their original location. The script also restarts the `pveproxy` service to apply the changes.

For HDDs/SSDs readings to work, the kernal module drivetemp must be installed.

### Install
```
apt-get install lm-sensors
wget https://github.com/Meliox/PVE-mods/blob/main/pve-mod-gui-temp.sh
```

![Promxox temp mod](https://github.com/Meliox/PVE-mods/blob/main/pve-mod-temp.png?raw=true)

### Configuration
Adjustments are available in the first part of the script, where paths can be edited, cpucore offset and display information.

If you find this helpful, a small donation is appreciated, [![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K8XPMSEBERH3W).


