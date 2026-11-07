# pve-mods: upgrade_access

Lets members of selected Proxmox groups (for example groups synced from an OIDC
provider) use two web UI features that Proxmox normally reserves for `root@pam`:

| Feature | Where in the UI | Config flag | Config groups |
|---|---|---|---|
| Upgrade console | Node → Updates → **Upgrade** | `upgrade=1` | `upgrade_groups` |
| Passwordless root shell | Node → **Shell** | `shell=1` | `shell_groups` |

Each feature is its own patch and can be enabled on its own.

## Warning

- **`upgrade_groups`: members effectively get root.** The Upgrade console runs
  `pveupgrade --shell` as root and can drop into an interactive root shell
  after the upgrade.
- **`shell_groups`: members get a passwordless root shell on the host**, the
  same as `root@pam`. Anyone in the group has full control of the node.
- Group members still need `Sys.Console` on `/nodes/<node>` (Proxmox enforces
  this on the shell endpoints). The `Administrator` and `PVEAdmin` roles include it.
- Only add people you would trust with the root password. Keep the groups small.
- The mod patches Proxmox's own files. A `pve-manager` update overwrites them.
  Enable the pve-mods dpkg trigger (`[pve_trigger] enabled=1` in
  `/etc/pve-mods/pve-mods.conf`) to re-apply them automatically. If the code
  around a patch changes, the patch fails safely and the mod is reverted.

## Why it is needed

Proxmox has no superuser role. The node shell API hard-codes `root@pam` in
`/usr/share/perl5/PVE/API2/Nodes.pm`:

- `get_shell_command` only returns the passwordless `/bin/login -f root` or
  `pveupgrade --shell` for `root@pam`. Every other user gets a plain
  `/bin/login` prompt, and OIDC users have no Linux password to log in with.
- The `vncshell` and `spiceshell` endpoints reject any command other than
  `login` unless the user is `root@pam`.
- The web UI also disables the Upgrade button unless the user name is `root@pam`.

No ACL or role can change this, even for an `Administrator`.

## How it works

| Patch | Target | Effect |
|---|---|---|
| `01-nodes-pm-upgrade-access.patch` | `Nodes.pm` | Adds `pvemods_upgrade_allowed()`. `get_shell_command` and the `vncshell`/`spiceshell` root checks accept the `upgrade` command for members of `upgrade_groups`. |
| `02-pvemanager-js-upgrade-button.patch` | `pvemanagerlib.js` | Removes the `root@pam`-only `disabled` flag from the Upgrade button. Non-members see the button but get a permission error. |
| `03-nodes-pm-shell-access.patch` | `Nodes.pm` | Adds `pvemods_shell_allowed()`. Members of `shell_groups` get `/bin/login -f root` instead of the login prompt. Over an SSH tunnel to another node it uses the same no-nested-login behaviour as `root@pam`. |

Both helpers read `/etc/pve-mods/conf.d/upgrade_access.conf` on every request.
They return true only if:

1. the request is for that feature's command (`upgrade`, or `login`/the default shell);
2. the group list for the feature is not empty;
3. the user is enabled and not expired in `user.cfg`;
4. the user is a member of one of the listed groups.

API tokens never match, since they are not users in `user.cfg`. Everything else
falls back to the stock Proxmox behaviour, so with the patch applied and an
empty group list nothing changes. Only `upgrade` and the default shell are
opened up. `ceph_install` and other commands stay `root@pam` only.

`pvedaemon` serves these API calls, so the mod's hooks restart it when patches
are applied or reverted, in addition to the usual `pveproxy` restart. The group
list in the config file is read per request and needs no restart.

## Configuration

`/etc/pve-mods/conf.d/upgrade_access.conf`:

```ini
[access]
# Upgrade console (Updates -> Upgrade, runs 'pveupgrade --shell' as root).
upgrade=1
upgrade_groups=pve-admins-authentik
# Node "Shell" tab without login prompt (passwordless ROOT shell).
shell=1
shell_groups=pve-admins-authentik
```

- `upgrade` / `shell` (0 or 1) decide which patches are applied. They are
  conditions in `patches.list`.
- `upgrade_groups` / `shell_groups` are comma separated Proxmox group names.
  Use the full name as shown in Datacenter → Permissions → Groups.
- `pve-mods-configure` sets the flag from the group list (empty list = disabled).

After changing a flag, apply or revert the patches:

```
/usr/lib/pve-mods/revert-patches.sh upgrade_access
/usr/lib/pve-mods/apply-patches.sh upgrade_access
```

Changing only the group lists needs neither step.

To enable the mod permanently, set `upgrade_access=1` under `[modules]` in
`/etc/pve-mods/pve-mods.conf`. This also lets the dpkg trigger re-apply it
after `pve-manager` updates.

## Using it with OIDC

Proxmox only knows about group membership if the OIDC realm syncs it from a
claim, or if you add the user to a group by hand.

### 1. Make the provider send groups

The ID token or userinfo must contain a claim with the list of group names as a
JSON array of strings. In Authentik the default `profile` scope mapping
already returns the user's groups in the `groups` claim. Keep `profile` in the
realm's scopes (the default is `email profile`). With other providers, add a
groups claim or scope mapping.

### 2. Configure the realm

Datacenter → Permissions → Realms → your OpenID realm → Edit, or:

```
pveum realm modify <realm> --groups-claim groups --groups-autocreate 1
```

- **Groups claim**: the claim name, for example `groups`.
- **Autocreate groups**: creates the groups on login. Without it, only groups
  that already exist in Proxmox are joined.
- **Overwrite groups** (`--groups-overwrite 1`): on each login, removes the
  user from all Proxmox groups first and re-adds the ones from the claim. This
  also removes memberships you set by hand, so leave it off if you mix both.

Proxmox adds the realm name to each synced group: the provider group
`pve-admins` in realm `authentik` becomes `pve-admins-authentik`. Use that name
in `upgrade_groups` / `shell_groups`. Group names with invalid characters are
skipped (see the syslog).

### 3. Give the group permissions

The mod only lifts the `root@pam` restriction. Members still need
`Sys.Console` on the node, for example:

```
pveum acl modify /nodes/<node> --groups pve-admins-authentik --roles PVEAdmin
```

Use `/` instead of `/nodes/<node>` to cover all nodes, or the `Administrator` role
for full rights.

### 4. Enable the mod

```
# /etc/pve-mods/conf.d/upgrade_access.conf
[access]
upgrade=1
upgrade_groups=pve-admins-authentik
shell=0
shell_groups=
```

```
/usr/lib/pve-mods/apply-patches.sh upgrade_access
```

### 5. Log in again and test

Group membership is synced at login, so log out and back in. Check it with:

```
pveum user list          # the "groups" column
pveum acl list
```

Then try Node → Updates → **Upgrade** (and the **Shell** tab if enabled).
Hard-refresh the browser (Ctrl+Shift+R) so the patched JS is loaded.

### Without a groups claim

You can also create a local Proxmox group and add the OIDC user by hand:

```
pveum group add upgraders
pveum user modify <user>@<realm> --groups upgraders
```

Then set `upgrade_groups=upgraders`. Do not combine this with
`groups-overwrite`, which would remove the membership at the next login.

## Troubleshooting

- **Still asked for a login in the Shell tab:** check that `shell=1` and the
  patch is applied (`grep -c pvemods_shell_allowed /usr/share/perl5/PVE/API2/Nodes.pm`
  should be above 0), that you are in a listed group (`pveum user list`), and that
  the group name includes the `-<realm>` suffix.
- **"user != root@pam" on Upgrade:** the Upgrade patch is not applied, or
  `upgrade_groups` does not include one of your groups. Restart `pvedaemon` if
  the patch was just applied manually.
- **Upgrade button greyed out:** the JS patch is not applied, or the browser
  cache is stale.
- **After a `pve-manager` update it stopped working:** Proxmox replaced the
  files. Re-run `apply-patches.sh upgrade_access`, or enable the pve-mods
  trigger.
- Check the syslog for the OIDC group sync messages (for example
  `journalctl | grep -i "openid"`).

## Uninstall

```
/usr/lib/pve-mods/revert-patches.sh upgrade_access
```

This reverts the patches and restarts `pveproxy` and `pvedaemon`. Then set
`upgrade_access=0` under `[modules]` in `/etc/pve-mods/pve-mods.conf`.
