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

Intel GPU permission handling can be tested without changing host capabilities
or services (the test uses isolated command stubs):

```bash
bash build/test/test-intel-permissions.sh
```

The pull request workflows also build and validate the package. Their
Proxmox-dependent patch tests run in the configured CI environment. The
`validate-mods` workflow must pass before a pull request is merged.

## Releasing

Maintainers only. Releases are created as drafts so custom text can be added before anyone is notified.

1. Merge the pull requests for the release. The workflow keeps the `chore/version-bump` pull request up to date.
2. Set the `bump:patch`, `bump:minor` or `bump:major` label on that pull request and merge it.
3. The merge tags `vX.Y.Z` and builds the package. A **draft** release named `pve-mods vX.Y.Z` is created. No notification is sent yet.
4. Open the draft on the Releases page and choose **Edit**. Add upgrade notes, warnings or highlights above the generated list.
5. Check that the `.deb`, `.asc` and `SHA256SUMS` assets are attached, then choose **Publish release**.

The notification email is sent when the release is published and contains the text as it was at that moment. Editing a published release does not send it again, so write the text before publishing.

Before re-running the `Build and Release` workflow for a tag, copy any text you added and delete the existing draft; the workflow does not update an existing release and would not keep manual edits.

## Pull requests

- Describe the problem and the change, and link any related issue.
- Mention any user-visible changes, configuration changes, or migration steps.
- Report which tests you ran and their results.
- Keep each pull request focused; avoid bundling unrelated changes.
