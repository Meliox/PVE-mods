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
const stats = {
    utilization: { gpu: 0 },
    memory: { used: 64, total: 4096, unit: 'MiB' },
    gtt: { used: 128, total: 8192, unit: 'MiB' },
    temperature: { gpu: 40 },
    frequency: { actual: 800, unit: 'MHz', label: 'freq1' },
    power: { draw: 10.041, unit: 'W', label: 'PPT' },
    fan: { speed: 0, unit: 'RPM' },
    sensors: { temp2: { value: 55, max: 90, crit: 100, label: 'junction', unit: 'C' } },
};
const device = { name: 'AMD <demo>', card: 'amd3', history_id: 'pci0000c6000', stats };
const info = { Graphics: { AMD: { amd3: device }, temp_unit: 'C' } };

test('AMD discovery and metric selection retain zeroes and omit missing metrics', () => {
    const devices = graphs.devices(info);
    assert.equal(devices.length, 1);
    assert.equal(devices[0].id, device.history_id);
    const fields = graphs.metricsFor('AMD', stats).map(m => m.field);
    assert.ok(fields.includes('gpu_util'));
    assert.ok(fields.includes('fan_rpm'));
    assert.ok(!fields.includes('mem_util'));
    assert.ok(!fields.includes('fan_speed'));
    assert.equal(graphs.metricsFor('AMD', {}).length, 0);
});
test('live and historical samples agree on memory percentages and units', () => {
    const sample = graphs.sample('AMD', stats);
    assert.equal(sample.gpu_util, 0);
    assert.equal(sample.mem_used, 64);
    assert.equal(sample.mem_used_pct, 1.5625);
    assert.equal(sample.gtt_used_pct, 1.5625);
    assert.equal(sample.fan_rpm, 0);
    const fields = definitions['pve-rrd-gpu'].fields;
    assert.equal(fields.find(f => f.name === 'gtt_used_pct').calculate(sample), sample.gtt_used_pct);
    assert.equal(fields.find(f => f.name === 'mem_used_pct').calculate(sample), sample.mem_used_pct);
    assert.equal(fields.find(f => f.name === 'gtt_used_pct').calculate({ gtt_total: 0 }), null);
});
test('summary and details encode metadata and attach appropriate units', () => {
    const html = context.renderGpuSummary.call({}, info);
    assert.ok(html.includes('AMD &lt;demo&gt;'));
    assert.ok(html.includes('GPU: 0%'));
    assert.ok(html.includes('40°C'));
    const rows = context.getGpuDetailRows(info, device);
    assert.equal(rows.find(r => r.property === 'fan / speed').value, '0 RPM');
    assert.equal(rows.find(r => r.property === 'memory / used').value, '64 MiB');
    assert.equal(rows.find(r => r.property === 'power / label').value, 'PPT');
    const fahrenheit = context.renderGpuSummary.call({}, { Graphics: { ...info.Graphics, temp_unit: 'F' } });
    assert.ok(fahrenheit.includes('104°F'));
    const fahrenheitRows = context.getGpuDetailRows({ Graphics: { ...info.Graphics, temp_unit: 'F' } }, device);
    assert.ok(fahrenheitRows.find(r => r.property === 'sensors / temp2 / value').value.includes('131°F'));
    assert.ok(fahrenheitRows.find(r => r.property === 'sensors / temp2 / max').value.includes('194°F'));
});
test('mixed vendors remain separate and detail properties sort alphabetically', () => {
    const mixed = { Graphics: { ...info.Graphics, Intel: { card0: { name: 'Intel', card: 'card0', stats: {} } },
        NVIDIA: { nvidia0: { name: 'NVIDIA', card: 'nvidia0', stats: {} } } } };
    assert.equal(graphs.devices(mixed).length, 3);
    assert.equal(context.getGpuDevices(mixed)[0].type, 'AMD');
    const rows = context.getGpuDetailRows(info, device);
    for (let i = 1; i < rows.length; i++) {
        assert.ok(rows[i - 1].property.localeCompare(rows[i].property, undefined,
            { numeric: true, sensitivity: 'base' }) <= 0);
    }
});
