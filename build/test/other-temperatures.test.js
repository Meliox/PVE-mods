const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(
    `${__dirname}/../../src/modules/node_info/files/PveMods_pvemanagerlib.js`, 'utf8',
);
const start = source.indexOf('renderer: function(otherInfo)');
const end = source.indexOf('\n        },', start);
const context = vm.createContext({
    Ext: {
        create: (_name, config) => ({
            getTemp: value => config.dstUnit === 'F' ? value * 1.8 + 32 : value,
            getUnit: () => config.dstUnit === 'F' ? '°F' : '°C',
        }),
        util: { Format: {
            number: value => value.toFixed(1),
            htmlEncode: value => value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
        } },
    },
    PVE: { mod: { TempHelper: { CELSIUS: 'C', FAHRENHEIT: 'F' } } },
    getSensorIgnoreThreshold: () => 5,
});
vm.runInContext(source.slice(source.indexOf('function getSensorLabel'),
    source.indexOf('function getModMetricState')), context);
const renderer = vm.runInContext(`(${source.slice(start + 'renderer: '.length, end).trim()})`, context);
const payload = {
    other: true, temp_unit: 'C', enhanced_sensors: {
        'demo-chip': {
            temp1: { input: { value: 32 } },
            temp2: { label: 'temp2', input: { value: 39 } },
            temp3: { label: ' TEMP3 ', input: { value: 44 } },
            temp4: { label: 'Motherboard', input: { value: 85 }, max: { value: 80 } },
            temp5: { label: 'Chipset <main>', input: { value: 95 }, crit: { value: 90 } },
            temp6: { label: '', input: { value: 2 } },
        },
    },
};

test('other temperatures omit generic channel labels but preserve readings and named labels', () => {
    const html = renderer(payload);
    assert.doesNotMatch(html, /temp\d/i);
    for (const reading of ['32.0°C', '39.0°C', '44.0°C', '85.0°C', '95.0°C']) {
        assert.ok(html.includes(reading), reading);
    }
    assert.ok(html.includes('Motherboard:&nbsp;'));
    assert.ok(html.includes('Chipset &lt;main&gt;:&nbsp;'));
    assert.ok(html.includes('demo-chip'));
    assert.ok(html.includes('color: #FFC300'));
    assert.ok(html.includes('color: red'));
    assert.ok(!html.includes('>2.0°C'));
});

test('other temperatures retain Fahrenheit conversion, category exclusions and disabled behavior', () => {
    const html = renderer({
        ...payload, temp_unit: 'F', enhanced_sensors: {
            ...payload.enhanced_sensors,
            'coretemp-isa-0000': { temp1: { input: { value: 70 } } },
        },
    });
    assert.ok(html.includes('89.6°F'));
    assert.ok(!html.includes('coretemp-isa-0000'));
    assert.equal(renderer({ ...payload, other: false }), '');
    assert.equal(renderer({ ...payload, enhanced_sensors: {} }), '');
});
