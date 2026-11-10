import assert from "node:assert/strict";
import { test } from "node:test";
import worker from "../apt-worker.mjs";

const origin = "https://pve-mods-apt.meliox.workers.dev";
const packagePath = "/pool/main/p/pve-mods/pve-mods_2.1.0_all.deb";
const downloadUrl = "https://github.com/Meliox/PVE-mods/releases/download/v2.1.0/pve-mods_2.1.0_all.deb";

function release(prerelease = false, draft = false) {
  return {
    prerelease,
    draft,
    id: 1,
    published_at: "2026-01-01T00:00:00Z",
    assets: [{ name: "pve-mods_2.1.0_all.deb", browser_download_url: downloadUrl }],
  };
}

test("resolves stable and prerelease assets for GET and HEAD", async t => {
  for (const prerelease of [false, true]) {
    for (const method of ["GET", "HEAD"]) {
      t.mock.method(globalThis, "fetch", async () => Response.json([release(prerelease)]));
      const response = await worker.fetch(new Request(origin + packagePath, { method }));
      assert.equal(response.status, 302);
      assert.equal(response.headers.get("Location"), downloadUrl);
      t.mock.restoreAll();
    }
  }
});

test("finds historical assets on later pages and skips drafts", async t => {
  const calls = [];
  t.mock.method(globalThis, "fetch", async url => {
    calls.push(url);
    if (calls.length === 1) {
      return Response.json([release(false, true)], {
        headers: { Link: '<https://api.github.com/repos/Meliox/PVE-mods/releases?per_page=100&page=2>; rel="next"' },
      });
    }
    return Response.json([release()]);
  });
  const response = await worker.fetch(new Request(origin + packagePath));
  assert.equal(response.status, 302);
  assert.equal(calls.length, 2);
  assert.match(calls[0], /page=1$/);
  assert.match(calls[1], /page=2$/);
});

test("resolves legacy pve-mod package assets", async t => {
  const filename = "pve-mod_1.0.7_all.deb";
  const url = "https://github.com/Meliox/PVE-mods/releases/download/v1.0.7/" + filename;
  t.mock.method(globalThis, "fetch", async () => Response.json([{
    ...release(),
    assets: [{ name: filename, browser_download_url: url }],
  }]));
  const response = await worker.fetch(new Request(origin + "/pool/main/p/pve-mods/" + filename));
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("Location"), url);
});

test("returns 404 after the final page for missing or draft assets", async t => {
  t.mock.method(globalThis, "fetch", async () => Response.json([release(false, true)]));
  const response = await worker.fetch(new Request(origin + packagePath));
  assert.equal(response.status, 404);
});

test("applies a combined newest-100 limit after reading all pages", async t => {
  const recent = Array.from({ length: 100 }, (_, id) => ({
    ...release(id % 2 === 0),
    id: id + 2,
    published_at: "2026-02-01T00:00:00Z",
    assets: [],
  }));
  for (const newerCount of [99, 100]) {
    let calls = 0;
    t.mock.method(globalThis, "fetch", async () => {
      calls++;
      if (calls === 1) {
        return Response.json([release()], {
          headers: { Link: '<https://api.github.com/repos/Meliox/PVE-mods/releases?page=2>; rel="next"' },
        });
      }
      return Response.json([
        ...recent.slice(0, newerCount),
        { ...release(false, true), published_at: "2026-03-01T00:00:00Z" },
        { ...release(), published_at: null },
      ]);
    });
    const response = await worker.fetch(new Request(origin + packagePath));
    assert.equal(response.status, newerCount === 99 ? 302 : 404);
    assert.equal(calls, 2);
    t.mock.restoreAll();
  }
});

test("breaks publication-date ties by descending release ID", async t => {
  const releases = Array.from({ length: 101 }, (_, id) => ({
    ...release(),
    id,
    assets: id === 0 ? release().assets : [],
  }));
  t.mock.method(globalThis, "fetch", async () => Response.json(releases));
  assert.equal((await worker.fetch(new Request(origin + packagePath))).status, 404);
});

test("reports upstream API failures rather than missing packages", async t => {
  t.mock.method(globalThis, "fetch", async () => new Response("Rate limited", { status: 403 }));
  const log = t.mock.method(console, "error", () => {});
  const response = await worker.fetch(new Request(origin + packagePath));
  assert.equal(response.status, 502);
  assert.equal(log.mock.calls.length, 1);
});

test("rejects invalid filenames and unsupported methods before fetching", async t => {
  const fetch = t.mock.method(globalThis, "fetch", async () => {
    throw new Error("Unexpected fetch");
  });
  assert.equal((await worker.fetch(new Request(origin + "/bad.deb"))).status, 400);
  const response = await worker.fetch(new Request(origin + packagePath, { method: "POST" }));
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("Allow"), "GET, HEAD");
  assert.equal(fetch.mock.calls.length, 0);
});

test("proxies metadata and the signing key without release lookup", async t => {
  for (const path of [
    "/pve-mods.gpg",
    "/dists/stable/InRelease",
    "/dists/testing/Release?test=1",
    "/changelogs/main/p/pve-mods/pve-mods_2.1.0/changelog",
  ]) {
    const fetch = t.mock.method(globalThis, "fetch", async (url, options) => {
      assert.equal(url, "https://meliox.github.io/PVE-mods" + path);
      assert.equal(options.method, "HEAD");
      return new Response(null, { status: 200 });
    });
    assert.equal((await worker.fetch(new Request(origin + path, { method: "HEAD" }))).status, 200);
    assert.equal(fetch.mock.calls.length, 1);
    t.mock.restoreAll();
  }
});
