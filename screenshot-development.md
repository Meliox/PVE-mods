# PVE-mods screenshot development

## Goal

Capture the **actual Proxmox WebUI**, temporarily supplying fictional data to
its existing widgets. Do not recreate the interface as an HTML mockup.

Node.js and Pillow are not required on the Proxmox host to take screenshots.
Use browser developer tools or the shared browser's Playwright tools.
Run optional image-processing and JavaScript test tooling on a development
machine, not on the hypervisor.

## Workflow

1. Install the intended UI changes, validate them, and reload Proxmox without
   cache. Restart `pveproxy` only when needed to deploy changes.
2. Open the relevant node/guest Summary page. Inspect the actual components,
   their renderers, and the expected data shape.
3. Save every property you override. Inject fictional data **in the browser
   only**. Do not edit collector JSON, RRD history, or hardware configuration
   just to take a screenshot.
4. Capture the actual widgets, using an element screenshot or a tightly
   bounded region. Include the Proxmox page framing only if it is requested
   and all identifying information has been anonymized.
5. Inspect the saved image. Check all names, values, units, headings, legends,
   and axis labels are visible. Retry clipped captures.
6. Restore the original renderers/stores/visibility/styles in a `finally`
   block. Reloading the page also clears browser-only modifications.

## Example: system and GPU fans

Open a node Summary and run this in the browser developer console. It uses
the existing `speedFan` and `gpuFans` widgets and their native renderers.
The headings are left unchanged; no simulation label is added to the image.

```javascript
(() => {
    if (globalThis.restoreFanDemo) {
        throw new Error('Restore the previous fan demo first');
    }
    const system = Ext.ComponentQuery.query('[itemId=speedFan]')[0];
    const gpu = Ext.ComponentQuery.query('[itemId=gpuFans]')[0];
    if (!system || !gpu) {
        throw new Error('Open the node Summary with PVE-mods loaded first');
    }

    const fans = {};
    [
        ['CPU fan', 1450],
        ['Front chassis fan', 920],
        ['Rear chassis fan', 1080],
        ['Auxiliary fan', 0],
    ].forEach(([label, value], index) => {
        fans[`fan${index + 1}`] = { label, input: { value, unit: 'RPM' } };
    });
    const sensorInfo = {
        fans: true,
        display_zero_speed_fans: true,
        enhanced_sensors: { demo: fans },
    };
    const Graphics = {};
    [
        ['Intel', 'Intel GPU', 1250, ' RPM'],
        ['AMD', 'AMD Radeon RX 7900 XTX', 1640, ' RPM'],
        ['NVIDIA', 'NVIDIA GeForce RTX 4070', 42, '%'],
    ].forEach(([type, name, speed, unit]) => {
        Graphics[type] = { demo: { name, stats: { fan: { speed, unit } } } };
    });
    const graphicsInfo = { enable_gpu: true, enable_fans: true, Graphics };
    const saved = [system, gpu].map(widget => ({
        widget,
        renderer: widget.renderer,
        setVisible: widget.setVisible,
        hidden: widget.hidden,
        text: widget.lastText,
        usage: widget.lastUsage,
    }));

    globalThis.restoreFanDemo = () => {
        saved.forEach(original => {
            const widget = original.widget;
            if (!widget.destroyed) {
                widget.renderer = original.renderer;
                widget.setVisible = original.setVisible;
                widget.updateValue(original.text, original.usage);
                widget.setVisible(!original.hidden);
            }
        });
        delete globalThis.restoreFanDemo;
    };

    try {
        saved.forEach((original, index) => {
            const widget = original.widget;
            const payload = index === 0 ? sensorInfo : graphicsInfo;
            widget.renderer = function () {
                return original.renderer.call(this, payload);
            };
            // Live feature-state updates can otherwise hide the GPU widget.
            widget.setVisible = function () {
                return original.setVisible.call(this, true);
            };
            widget.setVisible(true);
            widget.updateValue(widget.renderer());
        });
        system.ownerCt.updateLayout();
        gpu.el.dom.scrollIntoView({ block: 'center' });
        console.log('Fan demo ready. Restore with restoreFanDemo() or reload.');
    } catch (error) {
        globalThis.restoreFanDemo();
        throw error;
    }
})();
```

Capture the two fan widgets, then run:

```javascript
globalThis.restoreFanDemo();
```

These readings are fictional. Intel fan telemetry in particular is only a UI
exercise; do not imply that the collector exposes it on every Intel GPU.
AMD hwmon readings use RPM, while NVIDIA commonly reports a percentage.
Keep the simulation disclosure in accompanying documentation even when the
requested screenshot has no simulation text.

## Capturing with browser automation

Use the shared Proxmox page rather than opening another authenticated tab.
Retrieve current component IDs instead of hardcoding IDs from a previous
load:

```javascript
const ids = await page.evaluate(() =>
    ['speedFan', 'gpuFans'].map(itemId => {
        const widget = Ext.ComponentQuery.query(`[itemId=${itemId}]`)[0];
        if (!widget?.el) {
            throw new Error(`Widget ${itemId} is not rendered`);
        }
        return widget.el.id;
    }),
);
```

For a single widget:

```javascript
const element = page.locator(`[id="${ids[0]}"]`);
await element.scrollIntoViewIfNeeded();
const png = await element.screenshot();
```

For both adjacent widgets, obtain their bounding rectangles and screenshot
their union. Ensure the entire union is inside the viewport and is not
clipped by a scrolling parent. Inspect that the region contains only the
requested widgets before saving.

### Avoiding clipping

- Browser viewport size can change externally. Measure the current viewport
  immediately before capture; do not assume a previous size still applies.
- Scroll the actual container, not just the outer page.
- If a widget is wider than the viewport, temporarily resize it through
  ExtJS and allow its layout to settle, or temporarily position the actual
  element at the viewport origin and scale it to a conservative width.
  Save and restore all dimensions and inline styles.
- Do not capture a blank DOM clone of a chart: cloned `<canvas>` elements
  have no bitmap content. Prefer the original chart. If cloning is necessary,
  copy each source canvas bitmap with `drawImage`, and check for duplicate-ID
  or layout problems.
- Prefer a direct screenshot. If separate captures are combined, describe
  the result as a composite, not an unmodified full-page screenshot.
- Always restore temporary DOM changes and simulation state even if capture
  fails.

## Guest CPU/Memory chart simulation

Use the actual `pveGuestSummary` charts. Create a temporary `Ext.data.Store`
with fictional `time`, `cpu`, `maxmem`, `mem`, and pressure fields; include
`memhost` for VMs. The chart store expects CPU percentages, while the normal
guest RRD model converts fractional CPU input to percentages.

Save each chart's original store and title before calling `setStore`.
Keep byte values in bytes and pressure values in percent. Choose fixed
fictional timestamps. Restore original stores before destroying the temporary
store. Do not modify the shared real RRD store or its backend data.

## Privacy and final checks

- Use fictional node, cluster, guest, device, and account labels wherever
  visible. Hide IP addresses, real guest IDs/names, task logs, browser address
  bars, and account menus.
- Chart/fan-only captures are simplest because surrounding private data
  never enters the image.
- Do not assume a crop is safe: inspect the final PNG, including its edges.
- Confirm the image is not blank, clipped, or showing stale live readings.
- Preserve requested native headings and units.
- Save deliverables under `/root/` on this test host and link the actual
  files, not an editor diff/snapshot URI.
- Confirm live data is restored and Proxmox remains responsive afterward.

## Optional tooling and cleanup

If development tools are needed, install them on a workstation. If temporary
host installation is explicitly approved, record the exact installed package
list first. For cleanup, preview removal with APT, compare dependencies with
that installation record, and remove only those no longer required.
Do not blindly autoremove unrelated orphaned packages.

Node.js is used by the staged JavaScript tests; Pillow was used for optional
image composition. Both were removed from this test host after development.
The existing PVE-mods installation and UI changes do not depend on them.
