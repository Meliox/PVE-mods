const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(process.env.PVE_MANAGER_JS || '/usr/share/pve-manager/js/pvemanagerlib.js', 'utf8');
const start = source.indexOf("Ext.define('PVE.mod.GuestSummaryChart',");
const end = source.indexOf("Ext.define('PVE.panel.TemplateStatusView',", start);
assert.ok(start >= 0 && end > start, 'guest_summary patch must be applied to the test source');
const definitions = {};
const state = new Map();
const writes = [];
const stores = [];
const context = {
    gettext: text => text,
    PVE: { mod: {} },
    Proxmox: { Utils: { updateColumns() {} } },
    Ext: {
        define(name, definition) {
            definitions[name] = definition;
            if (name === 'PVE.mod.GuestSummaryChart') {
                context.PVE.mod.GuestSummaryChart = definition.statics;
            }
        },
        apply: Object.assign,
        isNumber: value => typeof value === 'number' && Number.isFinite(value),
        util: { Format: { number: value => String(value) } },
        state: { Manager: { getProvider: () => ({
            get: (key, fallback) => state.has(key) ? state.get(key) : fallback,
            set: (key, value) => { writes.push([key, value]); state.set(key, value); },
        }) } },
        create(name, config) {
            assert.equal(name, 'Proxmox.data.RRDStore');
            const store = {
                ...config, starts: 0, stops: 0,
                startUpdate() { this.starts++; },
                stopUpdate() { this.stops++; },
            };
            stores.push(store);
            return store;
        },
    },
};
vm.runInNewContext(source.slice(start, end), context);

function summary(type, template = false) {
    const events = {};
    const me = {
        pveSelNode: { data: { node: 'test-node', vmid: 100, type, template } },
        workspace: {}, statusStore: {},
        callParent() {},
        on: (event, listener) => { events[event] = listener; },
        mon() {},
    };
    definitions['PVE.guest.Summary'].initComponent.call(me);
    return { me, charts: me.items[0].items.slice(1), events, store: stores.at(-1) };
}

const fields = chart => Array.from(chart.fields, field => typeof field === 'string' ? field : field.yField);

for (const type of ['qemu', 'lxc']) {
    test(`${type}: five charts, shared store, axes and preserved independent graphs`, () => {
        const { charts, store, events } = summary(type);
        assert.deepEqual(Array.from(charts, chart => chart.title), [
            'CPU', 'Memory', 'Network Traffic', 'Disk IO', 'IO Pressure Stall',
        ]);
        assert.equal(store.rrdurl, `/api2/json/nodes/test-node/${type}/100/rrddata`);
        assert.equal(store.model, 'pve-rrd-guest');
        assert.equal(store.starts, 1);
        assert.ok(charts.every(chart => chart.store === store));
        events.destroy.call(store);
        assert.equal(store.stops, 1);
        const [cpu, memory, network, disk, io] = charts;
        assert.equal(cpu.xtype, 'pveModGuestSummaryChart');
        assert.deepEqual(fields(cpu), ['cpu', 'pressurecpusome', 'pressurecpufull']);
        assert.equal(cpu.unit, 'percent');
        assert.equal(cpu.axes[0].minimum, 0);
        assert.equal(cpu.axes[0].maximum, 100);
        assert.equal(memory.unit, 'bytes');
        assert.equal(memory.powerOfTwo, true);
        const memoryFields = ['maxmem', 'mem', ...(type === 'qemu' ? ['memhost'] : [])];
        assert.deepEqual(fields(memory), [...memoryFields, 'pressurememorysome', 'pressurememoryfull']);
        assert.deepEqual(Array.from(memory.axes[0].fields), memoryFields);
        assert.equal(memory.axes[1].position, 'right');
        assert.equal(memory.axes[1].minimum, 0);
        assert.equal(memory.axes[1].maximum, 100);
        assert.equal(memory.axes[1].majorTickSteps, 5);
        assert.deepEqual(Array.from(memory.axes[1].fields), ['pressurememorysome', 'pressurememoryfull']);
        assert.equal(memory.axes[1].renderer(null, 50), '50');
        assert.equal(memory.colors.length, memory.fields.length);
        assert.deepEqual(fields(network), ['netin', 'netout']);
        assert.deepEqual(fields(disk), ['diskread', 'diskwrite']);
        assert.deepEqual(fields(io), ['pressureiosome', 'pressureiofull']);
    });

    test(`${type}: templates remain graph-free without starting an RRD store`, () => {
        const count = stores.length;
        const { me } = summary(type, true);
        assert.deepEqual(Array.from(me.items[0].items, item => item.xtype), [
            'pveTemplateStatusView', 'pmxNotesView',
        ]);
        assert.equal(stores.length, count);
    });
}

test('QEMU memhost persistence; pressure toggles never modify host-memory state', () => {
    state.clear();
    writes.length = 0;
    const memory = summary('qemu').charts[1];
    assert.equal(memory.fields[2].hidden, true);
    memory.onLegendChange(null, { data: { disabled: false } }, null, 2);
    assert.equal(summary('qemu').charts[1].fields[2].hidden, false);
    for (const type of ['qemu', 'lxc']) {
        const chart = summary(type).charts[1];
        chart.fields.forEach((field, index) => {
            if (typeof field === 'object' && field.yField.startsWith('pressure')) {
                chart.onLegendChange(null, { data: { disabled: true } }, null, index);
            }
        });
    }
    assert.deepEqual(writes, [['pve-vm-hide-memhost', false]]);
});

test('pressure tooltips use percent, keep zero, and report unsupported metrics as No Data', () => {
    const factory = definitions['PVE.mod.GuestSummaryChart'].statics.pressureField;
    for (const field of ['pressurecpusome', 'pressurecpufull', 'pressurememorysome', 'pressurememoryfull']) {
        const series = factory(field, 'Pressure');
        assert.equal(series.fill, false);
        for (const value of [0, 12.5, 100, null, undefined, NaN]) {
            let html;
            series.tooltip.renderer(
                { setHtml: text => { html = text; } },
                { get: name => name === 'time' ? new Date(0) : value },
            );
            if (Number.isFinite(value) && typeof value === 'number') {
                assert.ok(html.startsWith(`Pressure: ${value}%<br>`));
                assert.ok(!html.includes('B'));
            } else {
                assert.equal(html, 'No Data');
            }
        }
    }
});

test('chart constructor restores decimal percent segmenter after toolkit base2 override', () => {
    const axis = { getPosition: () => 'right', setSegmenter: value => { axis.segmenter = value; } };
    const legend = { isDomLegend: true };
    const me = {
        callParent() {},
        header: {
            items: { findBy: predicate => { assert.ok(predicate(legend)); return legend; } },
            remove: (item, destroy) => { assert.equal(item, legend); assert.equal(destroy, false); },
        },
        addDocked: config => { assert.equal(config.items[0], legend); },
        getAxes: () => [axis],
        mon() {},
    };
    definitions['PVE.mod.GuestSummaryChart'].constructor.call(me, { unit: 'bytes' });
    assert.equal(axis.segmenter.type, 'numeric');
});
