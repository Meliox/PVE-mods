// Tests for build/compat-status.mjs.
// Run with: node --test build/test/compat-status.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  aggregate,
  mergeStatus,
  packageBadges,
  statusBadge,
} from "../compat-status.mjs";

const PKGS_OLD = { "pve-manager": "1:9.2.4-1", "proxmox-widget-toolkit": "5.1.3" };
const PKGS_NEW = { "pve-manager": "1:9.2.5-1", "proxmox-widget-toolkit": "5.1.4" };

function result(status, overrides = {}) {
  return {
    mod: "node_info",
    status,
    packages: PKGS_NEW,
    pve_mods_version: "2.2.4+daily.abc1234",
    run_url: "https://example.test/runs/2",
    date: "2026-11-26",
    ...overrides,
  };
}

test("pass updates last_passing and clears failure state", () => {
  const previous = {
    mod: "node_info",
    status: "failing",
    failing_since: "2026-11-20",
    last_passing: { date: "2026-11-19", packages: PKGS_OLD, run_url: "https://example.test/runs/1" },
    last_failing: { date: "2026-11-25", packages: PKGS_NEW, run_url: "https://example.test/runs/1" },
  };
  const merged = mergeStatus(previous, result("pass"));
  assert.equal(merged.status, "passing");
  assert.deepEqual(merged.last_passing.packages, PKGS_NEW);
  assert.equal(merged.last_passing.date, "2026-11-26");
  assert.equal(merged.last_failing, undefined);
  assert.equal(merged.failing_since, undefined);
});

test("fail preserves last_passing and sets failing_since once", () => {
  const previous = {
    mod: "node_info",
    status: "passing",
    last_passing: { date: "2026-11-19", packages: PKGS_OLD, run_url: "https://example.test/runs/1" },
  };
  const first = mergeStatus(previous, result("fail", { date: "2026-11-25" }));
  assert.equal(first.status, "failing");
  assert.equal(first.failing_since, "2026-11-25");
  assert.deepEqual(first.last_passing.packages, PKGS_OLD);
  assert.deepEqual(first.last_failing.packages, PKGS_NEW);

  // A later failure keeps the original failing_since date.
  const second = mergeStatus(first, result("fail"));
  assert.equal(second.failing_since, "2026-11-25");
  assert.equal(second.last_failing.date, "2026-11-26");
});

test("unavailable keeps previous pass/fail state but updates last_checked", () => {
  const previous = mergeStatus(undefined, result("fail", { date: "2026-11-25" }));
  const merged = mergeStatus(previous, result("unavailable"));
  assert.equal(merged.status, "unavailable");
  assert.equal(merged.last_checked, "2026-11-26");
  assert.equal(merged.failing_since, "2026-11-25");
  assert.deepEqual(merged.last_failing.packages, PKGS_NEW);
});

test("missing result carries previous state through unchanged", () => {
  const previous = mergeStatus(undefined, result("pass"));
  assert.deepEqual(mergeStatus(previous, undefined), previous);
});

test("badges reflect status and shorten package names", () => {
  const failing = mergeStatus(undefined, result("fail"));
  assert.deepEqual(statusBadge(failing), {
    schemaVersion: 1,
    label: "patch test",
    message: "failing since 2026-11-26",
    color: "red",
  });
  assert.equal(statusBadge(mergeStatus(undefined, result("pass"))).color, "brightgreen");
  assert.equal(statusBadge(undefined).message, "unknown");

  assert.deepEqual(packageBadges(mergeStatus(undefined, result("pass"))), {
    "pve-manager": { schemaVersion: 1, label: "pve-manager", message: "9.2.5-1", color: "blue" },
    "proxmox-widget-toolkit": { schemaVersion: 1, label: "widget-toolkit", message: "5.1.4", color: "blue" },
  });
  // Never passed: packages known from the failing run, versions unknown.
  assert.deepEqual(packageBadges(failing)["pve-manager"], {
    schemaVersion: 1,
    label: "pve-manager",
    message: "unknown",
    color: "lightgrey",
  });
});

test("package badges flag upstream-updated packages while failing", () => {
  const passed = mergeStatus(undefined, result("pass", { date: "2026-11-25", packages: PKGS_OLD }));
  const failed = mergeStatus(passed, result("fail"));
  const badges = packageBadges(failed);
  // Both packages changed between the pass and the failure -> orange.
  assert.equal(badges["pve-manager"].color, "orange");
  assert.equal(badges["pve-manager"].message, "9.2.4-1");
  // A package that did not change stays blue.
  const partialFail = mergeStatus(
    passed,
    result("fail", { packages: { ...PKGS_NEW, "proxmox-widget-toolkit": PKGS_OLD["proxmox-widget-toolkit"] } }),
  );
  assert.equal(packageBadges(partialFail)["proxmox-widget-toolkit"].color, "blue");
  assert.equal(packageBadges(partialFail)["pve-manager"].color, "orange");
  // Back to passing -> blue again.
  assert.equal(packageBadges(mergeStatus(failed, result("pass")))["pve-manager"].color, "blue");
});

test("aggregate writes status, badges and report for all known mods", () => {
  const dir = mkdtempSync(join(tmpdir(), "compat-status-"));
  try {
    const resultsDir = join(dir, "results");
    const dataDir = join(dir, "data");
    mkdirSync(resultsDir);
    mkdirSync(join(dataDir, "status"), { recursive: true });

    // Previously known mod without a result today (e.g. cancelled job).
    writeFileSync(
      join(dataDir, "status", "nag_screen.json"),
      JSON.stringify(mergeStatus(undefined, result("pass", { mod: "nag_screen", date: "2026-11-25" }))),
    );
    writeFileSync(join(resultsDir, "node_info.json"), JSON.stringify(result("fail")));

    const statuses = aggregate(resultsDir, dataDir, "2026-11-26T06:30:00Z");
    assert.deepEqual(statuses.map((s) => [s.mod, s.status]), [
      ["nag_screen", "passing"],
      ["node_info", "failing"],
    ]);

    const badge = JSON.parse(readFileSync(join(dataDir, "badges", "node_info.json"), "utf8"));
    assert.equal(badge.message, "failing since 2026-11-26");
    const pkgBadge = JSON.parse(readFileSync(join(dataDir, "badges", "node_info", "pve-manager.json"), "utf8"));
    assert.equal(pkgBadge.message, "unknown");
    const persisted = JSON.parse(readFileSync(join(dataDir, "status", "node_info.json"), "utf8"));
    assert.equal(persisted.last_failing.date, "2026-11-26");

    const report = readFileSync(join(dataDir, "report.md"), "utf8");
    assert.match(report, /\| `nag_screen` \| passing \|/);
    assert.match(report, /\| `node_info` \| failing \|/);
    assert.match(report, /Last updated: 2026-11-26T06:30:00Z/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
