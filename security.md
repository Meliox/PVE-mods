# Security Policy

## Supported Versions

These scripts and modifications are designed for use with **Proxmox Virtual Environment (PVE)**.

⚠️ **Note:**  
- Proxmox upgrades may overwrite modified files. Reinstallation of the mods may be required.  
- Functionality on unsupported versions is not guaranteed.

---

## Security Considerations

- **Root Access Required**:
  - All installation steps must be performed as `root`.
  - Normal users do not have access to required system paths.
  - Misuse may compromise your Proxmox installation.
- **Backups**: Scripts automatically back up modified system files before applying changes.
- **Network Security**:
  - UPS information requires network monitoring; secure communication is recommended.  
  - Multi-node UPS support assumes identical credentials across nodes, which may pose risks if not properly secured.

---

## Reporting a Vulnerability
If you discover a security issue in these scripts or modifications, please open an issue.

---

## Best Practices
- Review code prior to installation
- Always test on a **non-production node** before applying in production.
- Keep a full **system backup and VM/container snapshots** before installing modifications.
- Verify downloaded scripts from the official repo via checksum before execution.
- After upgrades, re-check whether mods are still applied correctly.
- Clear browser cache after applying GUI modifications.

---

## Disclaimer
These scripts are provided **as-is**, without warranty of any kind.  
Use at your own risk. The author(s) are not responsible for data loss, downtime, or security breaches resulting from the use of these modifications.