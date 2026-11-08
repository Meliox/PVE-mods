const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(`${process.env.AMD_TEST_ROOT}/usr/share/pve-manager/js/PveMods_PveNodeStatusView.js`, 'utf8');
const definitions = {};
const encode = value => String(value).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[c]);
const context = vm.createContext({
    gettext: text => text,
    PVE: { mod: { TempHelper: { CELSIUS: 0, FAHRENHEIT: 1 } } },
    Ext: {
        define: (name, config) => { definitions[name] = config; },
        isNumber: value => typeof value === 'number' && Number.isFinite(value),
        htmlEncode: encode,
        apply: Object.assign,
        emptyFn: () => {},
        util: { Format: { number: value => String(value) } },
        create: (name, config) => ({
            getTemp: value => config.dstUnit === 1 ? value * 9 / 5 + 32 : value,
            getUnit: () => config.dstUnit === 1 ? '°F' : '°C',
        }),
    },
});
vm.runInContext(source.slice(source.indexOf('function getSensorValue'), source.indexOf('function getTemperatureFeature')), context);
vm.runInContext(source.slice(source.indexOf('function getGpuDevices'), source.indexOf('function getUpsStatus')), context);
vm.runInContext(source.slice(source.indexOf("Ext.define('pve-rrd-gpu'"), source.indexOf("Ext.define('PVE.mod.SummaryChart'")), context);
const graphs = definitions['PVE.mod.GpuGraphs'];
const model = definitions['pve-rrd-gpu'];
// Values created inside the vm context have foreign prototypes that deepEqual rejects.
const plain = value => JSON.parse(JSON.stringify(value));

const intelStats = {
    frequency: { requested: 1200, actual: 1150, unit: 'MHz' },
    interrupts: { count: 321, unit: 'irq/s' },
    rc6: { value: 87.5, unit: '%' },
    power: { GPU: 3.25, Package: 11.5, unit: 'W' },
    engines: {
        'Render/3D': { busy: 12.5, sema: 0, wait: 0, unit: '%' },
        Blitter: { busy: 0, sema: 0, wait: 0, unit: '%' },
        Video: { busy: 45, sema: 0, wait: 0, unit: '%' },
        VideoEnhance: { busy: 5, sema: 0, wait: 0, unit: '%' },
    },
    clients: {},
};
const intel = { name: 'Intel <iGPU>', card: 'card0', history_id: 'pci000000020', drm_path: '/dev/dri/card0', stats: intelStats };
const nvidiaStats = {
    index: 0,
    name: 'RTX',
    temperature: { gpu: 54, unit: '°C' },
    utilization: { gpu: 12, memory: 7, unit: '%' },
    memory: { used: 1024, total: 10240, unit: 'MiB' },
    power: { draw: 95.5, limit: 320, unit: 'W' },
    fan: { speed: 35, unit: '%' },
};
const nvidia = { name: 'NVIDIA <RTX>', index: 0, card: 'nvidia0', history_id: 'pci000001000', stats: nvidiaStats };
const info = (extra = {}) => ({ Graphics: { Intel: { gpu0: intel }, NVIDIA: { gpu0: nvidia }, AMD: {}, temp_unit: 'C', ...extra } });

test('device discovery maps cards and history ids per vendor', () => {
    const devices = graphs.devices(info());
    assert.deepEqual(plain(devices.map(d => [d.type, d.card, d.id])),
        [['Intel', 'card0', 'pci000000020'], ['NVIDIA', 'nvidia0', 'pci000001000']]);
    assert.equal(devices[0].name, 'Intel <iGPU>');
});

test('device discovery derives missing card names and skips unusable entries', () => {
    const devices = graphs.devices({ Graphics: {
        Intel: {
            a: { drm_path: '/dev/dri/card1', stats: {} },
            bad: { card: 'card 1;', stats: {} },
            nostats: { card: 'card2' },
        },
        NVIDIA: {
            n: { index: 2, history_id: 'bad id', stats: {} },
        },
        AMD: {},
    } });
    assert.deepEqual(plain(devices.map(d => [d.type, d.card, d.id])),
        [['Intel', 'card1', 'card1'], ['NVIDIA', 'nvidia2', 'nvidia2']]);
});

test('Intel metrics cover engines, RC6, frequency and power and keep idle zeroes', () => {
    const fields = plain(graphs.metricsFor('Intel', intelStats).map(m => m.field));
    assert.deepEqual(fields, ['render_busy', 'video_busy', 'blitter_busy', 'videnh_busy', 'rc6',
        'freq_act', 'freq_req', 'power_gpu', 'power_pkg']);
    assert.ok(fields.includes('blitter_busy'), 'idle engine is still offered');
    const defaults = plain(graphs.metricsFor('Intel', intelStats).filter(m => m.on).map(m => m.field));
    assert.deepEqual(defaults, ['render_busy', 'video_busy', 'blitter_busy']);
    assert.equal(graphs.metricsFor('Intel', {}).length, 0);
    assert.equal(graphs.metricsFor('Intel', undefined).length, 0);
    assert.ok(!fields.includes('gpu_util') && !fields.includes('mem_used_pct'));
});

test('NVIDIA metrics cover utilization, memory, fan, power and temperature', () => {
    const metrics = graphs.metricsFor('NVIDIA', nvidiaStats);
    assert.deepEqual(plain(metrics.map(m => m.field)), ['gpu_util', 'mem_util', 'mem_used_pct', 'fan_speed',
        'power_draw', 'power_limit', 'temp_gpu']);
    assert.equal(metrics.find(m => m.field === 'mem_used_pct').get(nvidiaStats), 10);
    assert.ok(!metrics.some(m => m.field === 'fan_rpm' || m.field === 'gtt_used_pct'));
    assert.equal(graphs.metricsFor('NVIDIA', { utilization: { gpu: 0 } }).map(m => m.field).join(), 'gpu_util');
    assert.equal(graphs.metricsFor('NVIDIA', { memory: { used: 0, total: 0 } }).length, 0);
    assert.equal(graphs.metricsFor('NVIDIA', {}).length, 0);
});

test('each series gets a distinct palette colour', () => {
    const colors = graphs.metricsFor('Intel', intelStats).map(m => m.color);
    assert.equal(new Set(colors).size, colors.length);
});

test('live samples match the RRD field names for Intel and NVIDIA', () => {
    const intelRow = graphs.sample('Intel', intelStats);
    assert.equal(intelRow.render_busy, 12.5);
    assert.equal(intelRow.blitter_busy, 0);
    assert.equal(intelRow.rc6, 87.5);
    assert.equal(intelRow.freq_act, 1150);
    assert.equal(intelRow.power_pkg, 11.5);
    assert.ok(!('mem_used' in intelRow) && !('gtt_used' in intelRow));

    const row = graphs.sample('NVIDIA', nvidiaStats);
    assert.equal(row.gpu_util, 12);
    assert.equal(row.mem_used, 1024);
    assert.equal(row.mem_total, 10240);
    assert.equal(row.mem_used_pct, 10);
    assert.equal(row.fan_speed, 35);
    assert.ok(!('gtt_used' in row) && !('fan_rpm' in row));
    assert.equal(model.fields.find(f => f.name === 'mem_used_pct').calculate(row), row.mem_used_pct);
    assert.equal(model.fields.find(f => f.name === 'mem_used_pct').calculate({ mem_total: 0 }), null);
    assert.deepEqual(plain(graphs.sample('NVIDIA', {})), {});
    assert.deepEqual(plain(graphs.sample('Unknown', intelStats)), {});
});

test('Intel summary shows render and video load without temperature', () => {
    const html = context.renderGpuSummary.call({}, { Graphics: { Intel: { gpu0: intel }, temp_unit: 'C' } });
    assert.ok(html.includes('Intel &lt;iGPU&gt;'));
    assert.ok(html.includes('Render: 12.5%'));
    assert.ok(html.includes('Video: 45%'));
    assert.ok(!html.includes('VRAM') && !html.includes('Temp'));
});

test('Intel summary falls back to N/A without readings', () => {
    const html = context.renderGpuSummary.call({}, { Graphics: { Intel: { gpu0: { name: 'Intel', stats: {} } } } });
    assert.ok(html.includes('N/A'));
});

test('NVIDIA summary shows GPU, VRAM percent and temperature in both units', () => {
    const celsius = context.renderGpuSummary.call({}, { Graphics: { NVIDIA: { gpu0: nvidia }, temp_unit: 'C' } });
    assert.ok(celsius.includes('NVIDIA &lt;RTX&gt;'));
    assert.ok(celsius.includes('GPU: 12%'));
    assert.ok(celsius.includes('VRAM: 10%'));
    assert.ok(celsius.includes('54°C'));
    const fahrenheit = context.renderGpuSummary.call({}, { Graphics: { NVIDIA: { gpu0: nvidia }, temp_unit: 'F' } });
    assert.ok(fahrenheit.includes('129.2°F'));
});

test('summary highlights high load and temperature', () => {
    const hot = { ...nvidia, stats: { ...nvidiaStats, utilization: { gpu: 95 }, temperature: { gpu: 85 } } };
    const html = context.renderGpuSummary.call({}, { Graphics: { NVIDIA: { gpu0: hot } } });
    assert.ok(html.includes('color: #d9534f; font-weight: bold;">GPU: 95%'));
    assert.ok(html.includes('color: red; font-weight: bold;">85°C'));
    const warm = { ...nvidia, stats: { ...nvidiaStats, utilization: { gpu: 75 }, temperature: { gpu: 72 } } };
    const warmHtml = context.renderGpuSummary.call({}, { Graphics: { NVIDIA: { gpu0: warm } } });
    assert.ok(warmHtml.includes('color: #f0ad4e; font-weight: bold;">GPU: 75%'));
    assert.ok(warmHtml.includes('color: #FFC300; font-weight: bold;">72°C'));
});

test('summary lists every vendor with its own row', () => {
    const html = context.renderGpuSummary.call({}, info());
    assert.equal((html.match(/<tr>/g) || []).length, 2);
    assert.ok(html.indexOf('Intel &lt;iGPU&gt;') < html.indexOf('NVIDIA &lt;RTX&gt;'));
});

test('Intel detail rows attach units and encode values', () => {
    const rows = context.getGpuDetailRows(info(), intel);
    const value = property => rows.find(r => r.property === property)?.value;
    assert.equal(value('engines / Render/3D / busy'), '12.5 %');
    assert.equal(value('engines / Blitter / busy'), '0 %');
    assert.equal(value('frequency / actual'), '1150 MHz');
    assert.equal(value('power / Package'), '11.5 W');
    assert.equal(value('rc6 / value'), '87.5 %');
    assert.equal(value('name'), 'Intel &lt;iGPU&gt;');
    assert.equal(value('card'), 'card0');
    assert.ok(!rows.some(r => r.property.endsWith('unit')));
});

test('NVIDIA detail rows attach units and format the temperature', () => {
    const rows = context.getGpuDetailRows(info(), nvidia);
    const value = property => rows.find(r => r.property === property)?.value;
    assert.equal(value('memory / used'), '1024 MiB');
    assert.equal(value('memory / total'), '10240 MiB');
    assert.equal(value('power / draw'), '95.5 W');
    assert.equal(value('fan / speed'), '35 %');
    assert.equal(value('utilization / gpu'), '12 %');
    assert.ok(value('temperature / gpu').includes('54°C'));
    const fahrenheit = context.getGpuDetailRows(info({ temp_unit: 'F' }), nvidia);
    assert.ok(fahrenheit.find(r => r.property === 'temperature / gpu').value.includes('129.2°F'));
});

test('detail rows keep zero readings and mark missing ones as N/A', () => {
    const rows = context.getGpuDetailRows(info(), { stats: { utilization: { gpu: 0 }, fan: { speed: null } } });
    assert.equal(rows.find(r => r.property === 'utilization / gpu').value, '0 %');
    assert.equal(rows.find(r => r.property === 'fan / speed').value, 'N/A');
});

test('GPU temperature threshold from the status payload hides idle readings', () => {
    const shown = context.renderGpuSummary.call({}, info({ ignore_temp_below: 5 }));
    assert.ok(shown.includes('54°C'));
    const hidden = context.renderGpuSummary.call({}, info({ ignore_temp_below: 60 }));
    assert.ok(!hidden.includes('54°C'));
    assert.ok(hidden.includes('GPU: 12%'), 'other readings are still shown');
    const topLevel = context.renderGpuSummary.call({}, { ...info(), ignore_temp_below: 60 });
    assert.ok(!topLevel.includes('54°C'));
});

test('detail rows show the temperature regardless of the threshold', () => {
    const rows = context.getGpuDetailRows(info({ ignore_temp_below: 60 }), nvidia);
    assert.ok(rows.find(r => r.property === 'temperature / gpu').value.includes('54°C'));
});
