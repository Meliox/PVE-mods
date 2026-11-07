# Contributing

Thanks for your interest in contributing to PVE-mods! Bug reports, suggestions,
documentation improvements, and code contributions are welcome.

## Before you start

- For bugs, check whether the issue has already been reported. Include your PVE
  version, `pve-mods` version, steps to reproduce, and relevant error output.
- For larger changes or behavior changes, open an issue first to discuss the
  approach.
- Never include passwords, tokens, private keys, or other sensitive information
  in issues, logs, or pull requests. Redact hostnames and other identifying
  details when appropriate.

## Making changes

1. Fork the repository and create a branch for your change.
2. Keep changes focused, and update the relevant documentation when behavior,
   configuration, or installation steps change.
3. For a mod change, review its documentation under `src/modules/<mod>/` and
   follow the existing layout for source files, patches, configuration, and
   `files/files.list`.
4. Test your changes and include a summary of the changes and tests in your
   pull request.

## Testing

The source syntax checks can be run from the repository root:

```bash
bash build/test/test-syntax.sh all
```

This checks Perl, JavaScript, and shell syntax and requires Perl and Node.js.

The patch tests apply and revert patches on a Proxmox system and must be run as
root. They modify system files, so use a disposable Proxmox test environment,
not a production host:

```bash
bash build/test/test-patches.sh all
```

Package-upgrade patch reversion can also be tested with:

```bash
bash build/test/test-upgrade-revert.sh
```

The pull request workflows also build and validate the package. Their
Proxmox-dependent patch tests run in the configured CI environment.

## Pull requests

- Describe the problem and the change, and link any related issue.
- Mention any user-visible changes, configuration changes, or migration steps.
- Report which tests you ran and their results.
- Keep each pull request focused; avoid bundling unrelated changes.
