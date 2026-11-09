# node_search

Adds guest network information to resource lists and global Search. This module is independent of `guest_summary`, which changes VM/CT summary graphs only.

<p align="center"><img src="images/node-search.png" alt="Resource list with IP addresses, MAC addresses, guest hostname, guest OS and search counts (simulated data)"></p>

## Features

- Resource lists and global Search show IPv4/IPv6 addresses, MAC addresses, guest hostname and guest OS.
- Both Search views match IP addresses, MAC addresses, hostname and OS, case-insensitively.
- The resource-list heading shows total counts by resource type and **Search matches: shown / all**. Totals respect the selected tree scope and view filter, but not the search text; counts update when resources or search results change.
- The IP column sorts addresses numerically (IPv4 before IPv6), not alphabetically. Multiple addresses are sorted within each cell; rows are ordered by their first address, then remaining addresses.
- All visible resource-list and global Search columns are sized to displayed content once the initial guest collection completes. Widths default to 60-300 px, with maxima of 360 px for IPs, 180 px for MACs, 240 px for hostname and 260 px for OS; explicit column minimum/maximum widths take precedence. Hidden columns are unchanged. Manual resizing is preserved during subsequent updates; hover over IP, hostname or OS cells for full values if clipped.
- Running VMs obtain addresses, hostname and OS from QEMU Guest Agent. Enable the agent in the VM options and install/start it inside the guest. MAC addresses also come from the VM network configuration.
- Running containers obtain addresses from their interfaces. Stopped containers show configured static addresses and MACs; DHCP/SLAAC addresses cannot be known until running. Container hostname and OS columns are left blank because they do not use QEMU Guest Agent.
- Only interfaces whose MAC matches a network adapter configured in Proxmox contribute addresses. Internal Docker bridges and veth adapters with other MACs are excluded, and the MAC column lists configured adapters only.
- IPv4 and IPv6 (including private/ULA and link-local addresses) are supported. Loopback and unspecified addresses are omitted. No address is invented for unavailable guests or disabled agents. If configuration cannot be read, live interfaces are not included and the permission/error status is shown.
- Hover over IP cells for the source or error status. The optional **Guest information status** column exposes the same details. Configured MAC addresses have no runtime-status tooltip because they remain valid when the guest is stopped.
- Requests use the logged-in user's existing Proxmox permissions: configuration and container interfaces require `VM.Audit`; QEMU commands require `VM.GuestAgent.Audit` or `VM.GuestAgent.Unrestricted`. Permission failures are displayed, not bypassed.
- Collection runs only in an open browser session, caches results for 60 seconds, and processes at most four guests concurrently. Guest shutdown, migration and removal invalidate cached information. Collection-triggered list/search refreshes are batched into 100 ms windows to avoid rebuilding the grids for every guest response.

## Configuration

The module has no settings. Enable or disable it with option **[6] Node Search** in `pve-mods-configure`, or set `node_search=1` under `[modules]` in `/etc/pve-mods/pve-mods.conf`. It is disabled by default and independent of `node_info` and `guest_summary`. Reload the browser without cache afterwards.

## Tests

Run `bash build/test/node-search.sh` from the repository root. It tests collection, search, numeric IP sorting, column sizing, caching, batching, and patch application/reversion.
