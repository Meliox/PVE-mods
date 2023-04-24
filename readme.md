pve-mod-gui-temp

This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display temperature information. The modification includes three main steps:

1. Create backups of the original files located at `/usr/share/pve-manager/js/pvemanagerlib.js` and `/usr/share/perl5/PVE/API2/Nodes.pm` in the `/root/backup` directory.
2. Add a new line to the `Nodes.pm` file that reads the thermal state information of the host using the `sensors` command.
3. Modify the `pvemanagerlib.js` file to expand the space in the StatusView and add a new item to the items array that displays the temperature information in Celsius for the CPU cores and the NVME drive.

The script provides two options: `install` and `uninstall`. The `install` option installs the modification, while the `uninstall` option removes it by copying the backup files to their original location. The script also restarts the `pveproxy` service to apply the changes.

![alt text](https://github.com/Meliox/PVE-mods/blob/aster/pve-mod-temp.png?raw=true)
