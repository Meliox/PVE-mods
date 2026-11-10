# APT download Worker

Deploy [apt-worker.mjs](apt-worker.mjs) as the module source of the Cloudflare
Worker at `https://pve-mods-apt.meliox.workers.dev`. Updating this repository or
deploying GitHub Pages does not update the Worker; deploy it separately in the
Cloudflare dashboard.

The Worker proxies metadata and the public signing key to GitHub Pages. Package
requests redirect to matching assets in published GitHub Releases, including
stable releases and prereleases. Release lookup fetches all GitHub API pages,
then selects the 100 newest published releases by `published_at` descending
(release ID descending breaks ties), shared across both channels. Drafts and
unpublished releases do not count toward the limit. API responses may be cached
for five minutes.

The APT workflow applies the same 100-release limit before separating channels,
indexes their `.deb` assets, and uses `dpkg-scanpackages --multiversion`.
Releases without `.deb` assets count toward the limit but add no packages.
Package filenames must be unique within
each channel; conflicting downloads fail rather than overwrite an asset.
Signing and the Pages deployment cover both channels together.

The workflow extracts each package's embedded `changelog.gz` and publishes it
under `changelogs/main/p/pve-mods/pve-mods_VERSION/changelog`. Both signed Release
files advertise the `Changelogs` URL template used by `apt changelog` and Proxmox.
Missing or corrupt embedded changelogs fail the build. The Worker proxies these
paths to Pages without a separate deployment change.

Run the Worker tests with:

```bash
node --test build/test/apt-worker.test.mjs
```
