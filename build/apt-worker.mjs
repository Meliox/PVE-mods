const OWNER = "Meliox";
const REPO = "PVE-mods";
const PAGES_ORIGIN = "https://meliox.github.io";
const PAGES_PATH = "/PVE-mods";

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (!["GET", "HEAD"].includes(request.method)) {
      return new Response("Method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    if (url.pathname.endsWith(".deb")) {
      const filename = url.pathname.split("/").pop();
      if (!/^pve-mods_[a-zA-Z0-9.+~-]+_all\.deb$/.test(filename)) {
        return new Response("Invalid package", { status: 400 });
      }

      const releases = [];
      for (let page = 1; ; page++) {
        const api = `https://api.github.com/repos/${OWNER}/${REPO}/releases?per_page=100&page=${page}`;
        const response = await fetch(api, {
          headers: {
            Accept: "application/vnd.github+json",
            "User-Agent": "PVE-mods-APT",
          },
          cf: { cacheEverything: true, cacheTtl: 300 },
        });

        if (!response.ok) {
          console.error(`GitHub releases API returned ${response.status} on page ${page}`);
          return new Response("GitHub API error", { status: 502 });
        }

        releases.push(...await response.json());

        if (!/<[^>]+>;\s*rel="next"/.test(response.headers.get("Link") || "")) {
          break;
        }
      }

      const asset = releases
        .filter(release => !release.draft && release.published_at != null)
        .sort((a, b) => b.published_at.localeCompare(a.published_at) || b.id - a.id)
        .slice(0, 100)
        .flatMap(release => release.assets || [])
        .find(asset => asset.name === filename);

      return asset
        ? Response.redirect(asset.browser_download_url, 302)
        : new Response("Package not found", { status: 404 });
    }

    return fetch(PAGES_ORIGIN + PAGES_PATH + url.pathname + url.search, {
      method: request.method,
      headers: request.headers,
    });
  },
};
