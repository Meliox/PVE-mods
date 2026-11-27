const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(
    `${__dirname}/../../src/modules/node_info/files/PveMods_pvemanagerlib.js`, 'utf8',
);
const context = vm.createContext({
    gettext: text => text,
    getUpsStatus: value => ({ text: value }),
    formatUpsRuntime: value => `${value} seconds`,
});
vm.runInContext(source.slice(source.indexOf('function getUpsDetailRows'),
    source.indexOf('function refreshUpsDetails')), context);

test('UPS rows retain sections, units, fallbacks and zero values', () => {
    const rows = context.getUpsDetailRows({
        'device.mfr': 'Example <manufacturer>',
        'device.model': 'Example UPS',
        'ups.status': 'OL',
        'battery.charge': 0,
        'battery.runtime': 600,
        'ups.load': 0,
        'input.voltage': 230,
    }, 'demo-ups');
    const value = label => rows.find(row => row.property === label)?.value;
    assert.equal(value('Connection'), 'demo-ups');
    assert.equal(value('Manufacturer'), 'Example <manufacturer>');
    assert.equal(value('Capacity'), '0%');
    assert.equal(value('Load'), '0%');
    assert.equal(value('Estimated runtime'), '600 seconds');
    assert.equal(value('Input voltage'), '230 V');
    assert.equal(value('Serial number'), undefined);
    assert.equal(new Set(rows.map(row => row.id)).size, rows.length);
    assert.deepEqual([...new Set(rows.map(row => row.section))], ['Battery', 'Device', 'Power']);
});

test('UPS row IDs remain stable as values update or disappear', () => {
    const before = context.getUpsDetailRows({ 'ups.load': 10, 'battery.charge': 90 }, 'demo-ups');
    const after = context.getUpsDetailRows({ 'ups.load': 20 }, 'demo-ups');
    assert.equal(before.find(row => row.property === 'Load').id,
        after.find(row => row.property === 'Load').id);
    assert.equal(after.some(row => row.property === 'Capacity'), false);
});
