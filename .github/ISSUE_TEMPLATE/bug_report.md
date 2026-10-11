---
name: Bug report
about: Report a problem with PVE-mods
title: ''
labels: bug
assignees: ''

---

## Describe the bug
A clear description of the problem.

## Versions
- **PVE-mods version (REQUIRED - reports without it may be closed):**
  Run `dpkg-query -W -f='${Version}\n' pve-mods`
- **Proxmox VE version:**
  Run `pveversion -v`

## Affected module or feature
For example, `node_info`, `nag_screen`, installer, or upgrade.

## Steps to reproduce
1.
2.
3.

## Expected behavior
What did you expect to happen?

## Actual behavior
What happened instead? Include relevant error messages or logs.

## Additional information
- For `node_info` sensor issues, include relevant `sensors` output.
- For `node_info` issues, enable `mod_debug=1` in the `[debug]` section of `/etc/pve-mods/conf.d/node_info.conf`, restart `pveproxy`, and reproduce the issue to capture diagnostic logs. See the [debug guide](https://github.com/Meliox/PVE-mods/blob/main/src/modules/node_info/readme.md#debug-mode).
- For collector debug-file details, see the [per-collector debug files guide](https://github.com/Meliox/PVE-mods/blob/main/src/modules/node_info/readme.md#per-collector-debug-files).
- Relevant system journal entries may also help. For UI issues, check `journalctl -u pveproxy` around the time the problem occurred and include only relevant entries.
- Add screenshots or other details that may help reproduce the problem.
- Redact passwords, tokens, and other sensitive information before posting logs.
