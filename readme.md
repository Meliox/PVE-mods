# PVE-mods
PVE-mods is a Debian package that extends the Proxmox Virtual Environment (PVE) web interface with mods. Mods are enabled and configured through the interactive `pve-mods-configure` wizard.

<p align="center">
  <a href="images/proxmox-node-overview.png">
    <img src="images/proxmox-node-overview-small.png" alt="PVE-mods node summary on a simulated Proxmox VE node">
  </a>
  <br>
  <em>Click the image to view it in full size.</em>
</p>

Compatibility: PVE 9.2+ (some mods may work on older and some may require newer version of specific packages - generally combatibility is aimed towards newest and greatest due to security patching) 

All commands in this document (install, configure, upgrade, uninstall) must be run as `root` on the Proxmox VE host.

## Table of contents

- [Available mods](#available-mods)
- [How it works](#how-it-works)
- [Install](#install)
  - [Migrating from v1 (legacy scripts)](#migrating-from-v1-legacy-scripts)
  - [Manual configuration changes](#manual-configuration-changes)
  - [Re-applying patches after PVE upgrades](#re-applying-patches-after-pve-upgrades)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Notes](#notes)
  - [A mod cannot be installed or upgraded](#a-mod-cannot-be-installed-or-upgraded)
  - [Reverse proxy / CDN caching](#reverse-proxy--cdn-caching)
- [Support and contributing](#support-and-contributing)
  - [Donations](#donations)
- [License](#license)

> Looking for the old standalone bash scripts (v1)? They are archived, see the [legacy scripts readme](https://github.com/Meliox/PVE-mods/blob/e1c3eb0524fbb8ca940454aef3a51c0644a2d170/legacy-scripts/readme.md).

### Available mods

Each mod is optional and enabled individually in `pve-mods-configure`. See the mod readmes for details and screenshots.

| Mod | Description |
|-----|-------------|
| [`node_info`](src/modules/node_info/readme.md) | Adds live hardware data to the node summary panel: CPU/NVMe/HDD/SSD/RAM temperatures, fan speeds, GPU stats and history graphs (Intel/NVIDIA/AMD), UPS status, ZFS/SMART storage health and system/motherboard info. Data is collected by a background daemon. |
| [`nag_screen`](src/modules/nag_screen/readme.md) | Removes the subscription nag screen from the PVE web UI. |
| [`oidc_console_access`](src/modules/oidc_console_access/readme.md) | Allows selected Proxmox groups, including OIDC-synced groups, to use the node Upgrade console and/or passwordless root Shell. |
| [`guest_summary`](src/modules/guest_summary/readme.md) | Merges the VM and LXC summary graphs into five charts: CPU and memory with Some/Full pressure, plus network, disk IO and IO pressure stall. |
| [`node_search`](src/modules/node_search/readme.md) | Adds guest IP/MAC addresses, hostname and OS to the resource lists and global Search, with address search, numeric IP sorting and result counts. |

Some mods need additional packages on the host. Required tools are listed in each mod's readme (for example [`node_info` requirements](src/modules/node_info/readme.md#requirements)).

### How it works

1. The `pve-mods` package installs the patch files and scripts under `/usr/lib/pve-mods/`.
2. The main configuration file and per-mod settings are stored under `/etc/pve-mods/`.
3. Running `pve-mods-configure` prompts for which mods to enable and how to configure them.
4. The wizard applies the selected patches to the PVE system files and restarts `pveproxy`.
5. When upgrading `pve-mods`, the previous patches are reverted before package files are replaced, then the new version's patches are applied.
6. Optionally, patches are re-applied automatically after a `pve-manager` upgrade (see [Re-applying patches after PVE upgrades](#re-applying-patches-after-pve-upgrades)).

### Install

1. Install `pve-mods`. The installer downloads the latest release, verifies its checksum and asks for confirmation:

   ```bash
   curl -sL https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/install.sh | bash
   ```

2. Install the additional packages required by the mods you want to use - see each mod's readme linked in the [Available mods](#available-mods) section.
3. Run `pve-mods-configure` to enable/disable and configure mods.
4. Hard-refresh the browser (`Ctrl+F5`) so the patched web UI is loaded.

For multiple nodes, install `pve-mods` on all nodes with identical configuration.

#### Migrating from v1 (legacy scripts)

`pve-mods-configure` refuses to run if it detects a v1 script installation. Remove it first with the legacy script you installed, for example:

```bash
bash pve-mods-gui-sensors.sh uninstall
```

The scripts are available in [legacy-scripts/](legacy-scripts/readme.md).

#### Manual configuration changes
Configuration files are located in `/etc/pve-mods/`. After any manual edits, restart `pveproxy` to apply the changes:

```bash
systemctl restart pveproxy
```

#### Re-applying patches after PVE upgrades

Upgrading Proxmox packages (e.g. `pve-manager`) can overwrite the patched files and remove the mods. Enable the "Auto re-patch on PVE upgrade" option in `pve-mods-configure` to have `pve-mods` re-apply the enabled patches automatically after such upgrades. Otherwise, run `pve-mods-configure` again after a PVE upgrade.

If the patches of a mod are incompatible with the new PVE version, they are not applied: the mod is left unpatched (reverted to a clean state), a warning is printed, and the PVE upgrade itself is not blocked. Check for a newer `pve-mods` release that supports your PVE version, then run `pve-mods-configure` to apply the mod.

### Upgrade

`pve-mods` follows [Semantic Versioning](https://semver.org/), using `MAJOR.MINOR.PATCH` version numbers. Major releases may include breaking changes. Before upgrading to a new major version, read its release notes and changelog so you can review those changes and any required migration steps. Minor releases add backward-compatible functionality, and patch releases contain backward-compatible fixes.

To upgrade to the latest release, run the installer as `root`. It downloads and verifies the release package, then installs it over the current version; you do not need to uninstall first.

```bash
curl -sL https://raw.githubusercontent.com/Meliox/PVE-mods/refs/heads/main/install.sh | bash
```

If a mod's patch no longer matches its file, the upgrade still completes, but that mod is disabled. See [A mod cannot be installed or upgraded](#a-mod-cannot-be-installed-or-upgraded).

### Uninstall

```bash
apt-get remove pve-mods
```

Removing the package reverts all applied patches and preserves configuration without prompting.

To also delete all configuration and state (`/etc/pve-mods`, `/var/lib/pve-mods`), use:

```bash
apt-get purge pve-mods
```

Afterwards, remove the dependencies installed for the respective mods if no longer needed.

### Notes

#### A mod cannot be installed or upgraded

Mods work by patching Proxmox files. If a patch does not apply (when enabling a mod, after a Proxmox update, or during a `pve-mods` upgrade), either the file was changed by something other than `pve-mods` (another tweak script or a manual edit), or the patch is not compatible with the installed Proxmox version. The warning lists the affected file, the failing hunk and the package that owns the file.

1. Check whether the file is modified. If another tool re-edits it (for example a post-install hook in `/etc/apt/apt.conf.d/` that patches `proxmoxlib.js` after every `dpkg` run), disable that tool first. It would otherwise change the file again right after the next step.
2. Restore the original file by reinstalling the package that owns it, as named in the warning (`dpkg -S <file>` shows the owner), for example:

   ```bash
   apt reinstall proxmox-widget-toolkit
   ```

3. Enable the module again with `pve-mods-configure`.

If the patch still fails on a freshly reinstalled file, it is not compatible with the installed Proxmox version yet. Check for a newer `pve-mods` release, or report it through a [GitHub issue](https://github.com/Meliox/PVE-mods/issues) with your PVE and `pve-mods` versions.

#### Reverse proxy / CDN caching

If mod details appear when accessing a node directly but not through a reverse proxy or CDN, it may be serving a cached, unpatched `pvemanagerlib.js`. Its URL version may not change when the file is patched, so purge the cache for Proxmox JavaScript assets (such as `/pve2/js/`), disable asset caching for the PVE host, and hard-refresh the browser. After a Proxmox update, reapply the mod and purge the proxy/CDN cache again.

---

## Support and contributing

- Report bugs or request features through [GitHub issues](https://github.com/Meliox/PVE-mods/issues) (include your PVE and `pve-mods` versions).
- See [CONTRIBUTING.md](CONTRIBUTING.md) for how to contribute and run the tests.
- Report security vulnerabilities as described in [security.md](security.md).

### Donations

If you find this helpful, a small donation is appreciated:

Paypal: [![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K8XPMSEBERH3W)

Bitcoin (BTC): `16hg7syEJ3HkSP1PAANkpSW6pZ4vCdvUnK`

## License

Released under the [MIT License](LICENSE).
