# node_search

Shows guest IP addresses, MAC addresses, hostname and OS in the resource lists and global Search, and makes them searchable.

<p align="center"><img src="images/node-search.png" alt="Resource list with IP addresses, MAC addresses, guest hostname, guest OS and search counts (simulated data)"></p>

## Features

- New columns: IP addresses, MAC addresses, guest hostname and guest OS. An optional **Guest information status** column shows where the data came from or why it is missing.
- Both Search views match all of these fields, case-insensitively.
- The IP column sorts numerically (IPv4 before IPv6).
- The resource-list heading shows counts per resource type and **Search matches: shown / all**.
- Columns are sized to their content once the initial collection finishes. Manual resizing is kept.

## Where the data comes from

- **VMs:** addresses, hostname and OS come from the QEMU Guest Agent, so enable it in the VM options and run it in the guest.
- **Containers:** addresses come from the container interfaces. Stopped containers show their configured static addresses. Hostname and OS stay blank.
- **MAC addresses:** taken from the guest configuration.
- Only interfaces whose MAC matches a configured adapter are listed, so Docker bridges and veth devices are left out. Loopback and unspecified addresses are omitted.
- Nothing is invented for stopped guests, DHCP/SLAAC addresses or disabled agents.
- Requests use your own Proxmox permissions: `VM.Audit` for configuration and container interfaces, `VM.GuestAgent.Audit` or `VM.GuestAgent.Unrestricted` for QEMU. Permission errors are shown in the status column and tooltips.
- Data is collected only while the web UI is open, cached for 60 seconds, and fetched for at most four guests at a time.

## Configuration

The module has no settings. Enable or disable it with option **[6] Node Search** in `pve-mods-configure`, or set `node_search=1` under `[modules]` in `/etc/pve-mods/pve-mods.conf`. It is disabled by default and independent of the other modules. Reload the browser without cache afterwards.
