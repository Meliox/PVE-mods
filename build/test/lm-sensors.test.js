const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');

const root = process.env.NODE_INFO_TEST_ROOT;
const source = fs.readFileSync(`${root}/usr/share/pve-manager/js/PveMods_PveNodeStatusView.js`, 'utf8');
// Payloads published by the Perl collector for every fixture
const loadPayload = name => JSON.parse(fs.readFileSync(`${process.env.LM_SENSORS_PAYLOADS}/${name}`, 'utf8'));
const payload = loadPayload('01-synthetic-reference.json');
const realPayload = loadPayload('03-dell-t7910-dual-xeon.json');
const allPayloads = fs.readdirSync(process.env.LM_SENSORS_PAYLOADS)
    .filter(name => /^\d\d-.*\.json$/.test(name)).sort();

const encode = value => String(value).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[c]);
const context = vm.createContext({
    console,
    gettext: text => text,
    PVE: { mod: { TempHelper: { CELSIUS: 0, FAHRENHEIT: 1 } } },
    Ext: {
        htmlEncode: encode,
        util: { Format: { htmlEncode: encode, number: (value, format = '0') => {
            const decimals = format.split('.')[1] || '';
            const fixed = Number(value).toFixed(decimals.length);
            return decimals.includes('#') ? String(Number(fixed)) : fixed;
        } } },
        create: (name, config) => ({
            getTemp: value => config.dstUnit === 1 ? value * 9 / 5 + 32 : value,
            getUnit: () => config.dstUnit === 1 ? '&deg;F' : '&deg;C',
        }),
    },
});
vm.runInContext(source.slice(source.indexOf('function getSensorLabel'), source.indexOf('function refreshCpuThermalDetails')), context);

// Pulls a status item's renderer out of the item definition by balancing braces
function rendererFor(itemId) {
    const item = source.indexOf(`itemId: '${itemId}'`);
    const start = source.indexOf('renderer: function', item);
    let depth = 0;
    let end = source.indexOf('{', source.indexOf(')', start));
    for (; end < source.length; end++) {
        if (source[end] === '{') {
            depth++;
        } else if (source[end] === '}' && --depth === 0) {
            break;
        }
    }
    return vm.runInContext('(' + source.slice(start + 'renderer: '.length, end + 1) + ')', context);
}
const renderers = Object.fromEntries(
    ['thermalRam', 'thermalHdd', 'thermalNvme', 'otherThermals', 'speedFan'].map(id => [id, rendererFor(id)]));
const renderCpu = info => context.renderCpuThermal.call({}, info);
// Values built inside the vm context have foreign prototypes that deepEqual rejects.
const plain = value => JSON.parse(JSON.stringify(value));

const feature = (value, extra = {}) => ({ input: { value, quantity: 'temperature', unit: 'C' }, ...extra });
const enabled = (sensors, extra = {}) => ({
    cpu: true, ram: true, hdd: true, nvme: true, other: true, fans: true,
    temp_unit: 'C', ignore_temp_below: 5, enhanced_sensors: sensors, ...extra,
});
const RED = 'color: red; font-weight: bold;';
const YELLOW = 'color: #FFC300; font-weight: bold;';

test('collector payload carries the flags and sensor data the GUI expects', () => {
    for (const flag of ['cpu', 'ram', 'hdd', 'nvme', 'other', 'fans']) {
        assert.equal(payload[flag], true, flag);
    }
    for (const id of ['thermalCpu', 'thermalRam', 'thermalHdd', 'thermalNvme', 'otherThermals', 'speedFan']) {
        assert.equal(context.getModMetricState(id, payload), 'ready', id);
    }
});

// ---- Helpers ----------------------------------------------------------------
test('getSensorValue reads nested and plain readings and rejects non-numbers', () => {
    const value = context.getSensorValue;
    assert.equal(value({ input: { value: 41.5 } }, 'input'), 41.5);
    assert.equal(value({ input: { value: 41.5 }, max: { value: 55 } }, 'max'), 55, 'other subfeatures');
    assert.equal(value({ input: '12.5' }, 'input'), 12.5);
    assert.equal(value({ input: 0 }, 'input'), 0, 'zero is a valid reading');
    for (const bad of [null, undefined, true, '', '  ', 'abc', NaN, Infinity, {}]) {
        assert.ok(Number.isNaN(value({ input: bad }, 'input')), `rejects ${String(bad)}`);
    }
    assert.ok(Number.isNaN(value(null, 'input')));
    assert.ok(Number.isNaN(value('text', 'input')));
    assert.ok(Number.isNaN(value({}, 'input')));
});

test('getSensorLabel falls back unless the feature has a string label', () => {
    assert.equal(context.getSensorLabel({ label: 'Core 0' }, 'temp2'), 'Core 0');
    assert.equal(context.getSensorLabel({ label: 5 }, 'temp2'), 'temp2');
    assert.equal(context.getSensorLabel(null, 'temp2'), 'temp2');
});

test('getTemperatureFeature prefers the label key, then a matching label, then the first temp', () => {
    const get = context.getTemperatureFeature;
    const group = { Composite: { a: 1 }, temp1: { label: 'Other', b: 2 } };
    assert.equal(get(group, 'Composite').a, 1, 'direct label key');
    const byLabel = { temp1: { label: 'Sensor 1' }, temp2: { label: 'Composite', c: 3 } };
    assert.equal(get(byLabel, 'Composite').c, 3, 'temp key whose label matches');
    assert.equal(get(byLabel, 'Missing').label, 'Sensor 1', 'first temp key as a last resort');
    assert.equal(get({ Adapter: 'x' }, 'Composite'), null);
    assert.equal(get(null, 'Composite'), null);
    assert.equal(get('x', 'Composite'), null);
});

test('payload and enabled-flag helpers tolerate missing data', () => {
    assert.deepEqual({ ...context.getSensorPayload({ enhanced_sensors: { a: 1 } }) }, { a: 1 });
    assert.deepEqual({ ...context.getSensorPayload(null) }, {});
    assert.deepEqual({ ...context.getSensorPayload({ enhanced_sensors: 'x' }) }, {});
    assert.equal(context.isSensorEnabled({ cpu: true }, 'cpu'), true);
    assert.equal(context.isSensorEnabled({ cpu: false }, 'cpu'), false);
    assert.equal(context.isSensorEnabled({ cpu: true, disabled: true }, 'cpu'), false);
    assert.equal(context.isSensorEnabled({ cpu: 'yes' }, 'cpu'), false);
    assert.equal(context.isSensorEnabled(null, 'cpu'), false);
});

test('getModMetricState reports pending, disabled and ready', () => {
    const state = context.getModMetricState;
    assert.equal(state('thermalCpu', null), 'pending');
    assert.equal(state('thermalCpu', { disabled: true }), 'disabled');
    assert.equal(state('thermalCpu', { cpu: false, enhanced_sensors: {} }), 'disabled');
    assert.equal(state('thermalCpu', { cpu: true }), 'pending', 'enabled but no data yet');
    assert.equal(state('thermalCpu', { cpu: true, enhanced_sensors: {} }), 'ready');
    assert.equal(state('speedFan', { fans: true, enhanced_sensors: {} }), 'ready');
    assert.equal(state('otherThermals', { other: false }), 'disabled');
    assert.equal(state('gpuFans', { enable_gpu: true, enable_fans: false }), 'disabled');
    assert.equal(state('gpu_details', { enable_gpu: true, Graphics: {} }), 'ready');
    assert.equal(state('storageHealth', { status: 'ok' }), 'ready');
    assert.equal(state('storageHealth', {}), 'pending');
});

test('getSensorIgnoreThreshold defaults to 5 and converts to the display unit', () => {
    const celsius = { getTemp: v => v };
    const fahrenheit = { getTemp: v => v * 9 / 5 + 32 };
    assert.equal(context.getSensorIgnoreThreshold({}, celsius), 5);
    assert.equal(context.getSensorIgnoreThreshold({ ignore_temp_below: 10 }, celsius), 10);
    assert.equal(context.getSensorIgnoreThreshold({ ignore_temp_below: 'x' }, celsius), 5);
    assert.equal(context.getSensorIgnoreThreshold({ ignore_temp_below: 10 }, fahrenheit), 50);
});

// ---- CPU thermal state ---------------------------------------------------------
test('CPU summary uses the cores of a package and escapes the model name', () => {
    const groups = context.getCpuThermalGroups(payload);
    assert.equal(groups.length, 1);
    assert.equal(groups[0].label, 'Package 0');
    assert.equal(groups[0].model, 'Intel(R) Core(TM) Test <CPU>');
    assert.equal(groups[0].rows.length, 3);
    assert.deepEqual(plain(groups[0].selected.map(row => row.label)), ['Core 0', 'Core 1']);
    const html = renderCpu(payload);
    assert.ok(html.includes('Intel(R) Core(TM) Test &lt;CPU&gt;'));
    assert.ok(html.includes('Min: <span style="">48.0&deg;C</span>'));
    assert.ok(html.includes('Avg: <span style="">52.0&deg;C</span>'));
    assert.ok(html.includes('Max: <span style="">56.0&deg;C</span>'));
    assert.ok(html.includes('(2 sensors)'));
});

test('CPU summary lists both packages of a real dual-socket capture', () => {
    const groups = context.getCpuThermalGroups(realPayload);
    assert.deepEqual(plain(groups.map(group => group.label)), ['Package 0', 'Package 1']);
    assert.ok(groups.every(group => group.rows.length === 7 && group.selected.length === 6));
    const html = renderCpu(realPayload);
    assert.equal((html.match(/<tr>/g) || []).length, 2, 'one row per package');
    assert.ok(html.includes('Min: <span style="">35.0&deg;C</span>'));
    assert.ok(html.includes('Max: <span style="">40.0&deg;C</span>'), 'hottest core of package 1 is 40');
});

test('CPU summary colours readings against the max and critical thresholds', () => {
    const chip = (value, max, crit) => ({
        'coretemp-isa-0000': {
            temp1: { label: 'Package id 0', input: { value }, max: { value: max }, crit: { value: crit } },
            temp2: { label: 'Core 0', input: { value }, max: { value: max }, crit: { value: crit } },
        },
    });
    assert.ok(renderCpu(enabled(chip(60, 75, 85))).includes('style="">60.0&deg;C'));
    assert.ok(renderCpu(enabled(chip(76, 75, 85))).includes(`style="${YELLOW}">76.0&deg;C`));
    assert.ok(renderCpu(enabled(chip(86, 75, 85))).includes(`style="${RED}">86.0&deg;C`));
});

test('AMD k10temp prefers Tdie over Tctl, and uses the CCDs when there are several', () => {
    const tdie = context.getCpuThermalGroups(enabled({
        'k10temp-pci-00c3': { temp1: { label: 'Tctl', input: { value: 60 } }, temp2: { label: 'Tdie', input: { value: 50 } } },
    }));
    assert.deepEqual(plain(tdie[0].selected.map(row => row.label)), ['Tdie']);
    const tctl = context.getCpuThermalGroups(enabled({
        'k10temp-pci-00c3': { temp1: { label: 'Tctl', input: { value: 60 } } },
    }));
    assert.deepEqual(plain(tctl[0].selected.map(row => row.label)), ['Tctl']);
    const ccds = context.getCpuThermalGroups(enabled({
        'k10temp-pci-00c3': {
            temp1: { label: 'Tctl', input: { value: 60 } },
            temp3: { label: 'Tccd1', input: { value: 55 } },
            temp4: { label: 'Tccd2', input: { value: 57 } },
        },
    }));
    assert.deepEqual(plain(ccds[0].selected.map(row => row.label)), ['Tccd1', 'Tccd2']);
    assert.equal(ccds[0].label, 'k10temp-pci-00c3', 'no package id: the chip name is the label');
});

test('Raspberry Pi cpu_thermal shows a single sensor', () => {
    const html = renderCpu(enabled({
        'cpu_thermal-virtual-0': { temp1: { input: { value: 47.2 } }, cpu_model: 'Raspberry Pi 5' },
    }));
    assert.ok(html.includes('Raspberry Pi 5'));
    assert.ok(html.includes('47.2&deg;C'));
    assert.ok(html.includes('(1 sensor)'));
    assert.ok(!html.includes('Min:'));
});

test('CPU summary converts to Fahrenheit and hides idle readings', () => {
    const fahrenheit = renderCpu({ ...payload, temp_unit: 'F' });
    assert.ok(fahrenheit.includes('Avg: <span style="">125.6&deg;F</span>'));
    assert.ok(renderCpu({ ...payload, ignore_temp_below: 50 }).includes('(1 sensor)'), 'cores below 50 are dropped');
    assert.equal(renderCpu({ ...payload, ignore_temp_below: 90 }), 'N/A', 'nothing left to show');
});

test('CPU summary is N/A when disabled or empty', () => {
    assert.equal(renderCpu({ ...payload, cpu: false }), 'N/A');
    assert.equal(renderCpu(null), 'N/A');
    assert.equal(renderCpu(enabled({})), 'N/A');
    assert.equal(renderCpu(enabled({ 'coretemp-isa-0000': 'broken' })), 'N/A');
});

test('CPU detail rows list every sensor of the selected package', () => {
    const widget = { cpuThermalGroups: context.getCpuThermalGroups(payload) };
    const rows = context.getCpuThermalDetailRows(widget, 'coretemp-isa-0000');
    assert.deepEqual(plain(rows.map(row => row.sensor)), ['Core 0', 'Core 1', 'Package id 0']);
    assert.equal(rows[0].value, 48);
    assert.equal(rows[0].model, 'Intel(R) Core(TM) Test <CPU>');
    assert.deepEqual(plain(context.getCpuThermalDetailRows(widget, 'other')), []);
});

// ---- RAM -------------------------------------------------------------------------
test('RAM temperatures list DIMMs by slot with their readings', () => {
    const html = renderers.thermalRam(payload);
    assert.ok(html.includes('1:&nbsp;<span style="">41.5&deg;C</span>'));
    assert.ok(html.includes('2:&nbsp;<span style="">43.3&deg;C</span>'), '43.25 rounds to one decimal');
    assert.ok(html.indexOf('1:&nbsp;') < html.indexOf('2:&nbsp;'));
});

test('RAM temperatures sort slots numerically and colour thresholds', () => {
    const dimm = (slot, value, max, crit) => ({
        dimm_slot: slot, temp1: { input: { value }, max: { value: max }, crit: { value: crit } },
    });
    const html = renderers.thermalRam(enabled({
        DIMM10: dimm(10, 40, 55, 85), DIMM2: dimm(2, 56, 55, 85), DIMM1: dimm(1, 90, 55, 85),
    }));
    assert.ok(html.indexOf('1:&nbsp;') < html.indexOf('2:&nbsp;') && html.indexOf('2:&nbsp;') < html.indexOf('10:&nbsp;'));
    assert.ok(html.includes(`2:&nbsp;<span style="${YELLOW}">`));
    assert.ok(html.includes(`1:&nbsp;<span style="${RED}">`));
    assert.ok(html.includes('10:&nbsp;<span style="">'));
});

test('RAM temperatures handle units, thresholds and missing data', () => {
    assert.ok(renderers.thermalRam({ ...payload, temp_unit: 'F' }).includes('106.7&deg;F'));
    assert.equal(renderers.thermalRam({ ...payload, ram: false }), '');
    assert.equal(renderers.thermalRam(enabled({})), 'N/A');
    assert.equal(renderers.thermalRam(enabled({ DIMM1: { temp1: { input: { value: 3 } } } })), 'N/A',
        'readings below the ignore threshold are hidden');
    assert.equal(renderers.thermalRam(enabled({ DIMM1: { temp1: { input: { value: 'x' } } } })), 'N/A');
});

// ---- HDD / SSD -------------------------------------------------------------------
test('HDD temperatures show model, serial and reading', () => {
    const html = renderers.thermalHdd(payload);
    assert.ok(html.includes('1. Test SSD&nbsp;(SER123)'));
    assert.ok(html.includes('34.0&deg;C'));
    assert.equal((html.match(/<tr>/g) || []).length, 1, 'only drivetemp-scsi chips are listed');
});

test('HDD temperatures number drives, hide unknown serials and colour thresholds', () => {
    const drive = (value, serial, max = 70, crit = 85) => ({
        model: 'Disk', serial,
        temp1: { label: 'Drive Temperature', input: { value }, max: { value: max }, crit: { value: crit } },
    });
    const html = renderers.thermalHdd(enabled({
        'drivetemp-scsi-1-0': drive(75, 'unknown'), 'drivetemp-scsi-0-0': drive(40, 'S1'),
        'drivetemp-scsi-10-0': drive(90, ''),
    }));
    assert.ok(html.indexOf('1. Disk&nbsp;(S1)') < html.indexOf('2. Disk</td>'));
    assert.ok(html.includes('2. Disk</td>'), 'unknown serial is not shown');
    assert.ok(html.includes(`style="${YELLOW}">75.0&deg;C`));
    assert.ok(html.includes(`style="${RED}">90.0&deg;C`));
    assert.ok(html.includes('3. Disk&nbsp;()'), 'an empty serial is shown as empty parentheses');
});

test('HDD temperatures report N/A or nothing', () => {
    assert.equal(renderers.thermalHdd({ ...payload, hdd: false }), '');
    assert.equal(renderers.thermalHdd(enabled({})), 'N/A');
    assert.equal(renderers.thermalHdd(enabled({
        'drivetemp-scsi-0-0': { temp1: { label: 'Drive Temperature', input: { value: 2 } } },
    })), 'N/A');
    assert.ok(renderers.thermalHdd({ ...payload, temp_unit: 'F' }).includes('93.2&deg;F'));
});

// ---- NVMe ------------------------------------------------------------------------
test('NVMe temperatures use the Composite sensor and show the serial', () => {
    const html = renderers.thermalNvme(payload);
    assert.ok(html.includes('Test NVMe&nbsp;(NVME456)'));
    assert.ok(html.includes('38.9&deg;C'), 'Composite 38.85 rather than Sensor 1');
    assert.ok(!html.includes('39.9'));
});

test('NVMe temperatures sort by chip, colour thresholds and omit empty serials', () => {
    const nvme = (value, serial) => ({
        model: 'Fast', serial,
        temp1: { label: 'Composite', input: { value }, max: { value: 80 }, crit: { value: 90 } },
    });
    const html = renderers.thermalNvme(enabled({
        'nvme-pci-0700': nvme(95, ''), 'nvme-pci-0600': nvme(82, 'A1'),
    }));
    assert.ok(html.indexOf('Fast&nbsp;(A1)') < html.indexOf('Fast</td>'));
    assert.ok(html.includes(`style="${YELLOW}">82.0&deg;C`));
    assert.ok(html.includes(`style="${RED}">95.0&deg;C`));
    assert.equal(renderers.thermalNvme({ ...payload, nvme: false }), '');
    assert.equal(renderers.thermalNvme(enabled({})), 'N/A');
});

// ---- Other temperatures ----------------------------------------------------------
test('other temperatures exclude CPU, drive and DIMM chips and show labelled readings', () => {
    const html = renderers.otherThermals(payload);
    assert.ok(html.includes('>acpitz-acpi-0<'));
    assert.ok(html.includes('>nct6775-isa-0290<'));
    assert.ok(html.includes('SYSTIN:&nbsp;<span style="">38.0&deg;C</span>'));
    assert.ok(html.indexOf('acpitz-acpi-0') < html.indexOf('nct6775-isa-0290'), 'rows are sorted');
    for (const excluded of ['coretemp', 'nvme-pci', 'drivetemp', 'DIMM']) {
        assert.ok(!html.includes(`>${excluded}`), excluded);
    }
});

test('other temperatures join several sensors, colour thresholds and skip fan-only chips', () => {
    const html = renderers.otherThermals(enabled({
        'it8686-isa-0a40': {
            temp1: { label: 'VRM', input: { value: 85 }, max: { value: 80 }, crit: { value: 100 } },
            temp2: { input: { value: 95 }, crit: { value: 90 } },
        },
        'fan-only-isa-0': { fan1: { input: { value: 1000 } } },
        'plain-text': 'text',
    }));
    assert.ok(html.includes(`VRM:&nbsp;<span style="${YELLOW}">85.0&deg;C</span>&nbsp;| <span style="${RED}">95.0&deg;C`));
    assert.ok(!html.includes('temp2:'), 'a generic tempN name is not shown as a label');
    assert.ok(!html.includes('fan-only'));
    assert.ok(!html.includes('plain-text'));
    assert.equal(renderers.otherThermals(enabled({ 'fan-only-isa-0': { fan1: {} } })), '', 'no rows renders nothing');
    assert.equal(renderers.otherThermals({ ...payload, other: false }), '');
});

test('other temperature labels are HTML-escaped', () => {
    const html = renderers.otherThermals(enabled({
        'it8686-isa-0a40': { temp1: { label: '<b>VRM</b>', input: { value: 40 } } },
    }));
    assert.ok(html.includes('&lt;b&gt;VRM&lt;/b&gt;:&nbsp;<span style="">40.0&deg;C</span>'));
    assert.ok(!html.includes('<b>VRM'));
});

// ---- Fans ------------------------------------------------------------------------
test('fans from the collector payload show labels, units and optional zero speeds', () => {
    const html = renderers.speedFan(payload);
    assert.ok(html.includes('>CPU Fan</td>'));
    assert.ok(html.includes('1450 RPM'));
    assert.ok(html.includes('>Fan2</td>') && html.includes('0 RPM'), 'zero speed shown when enabled');
    const hidden = renderers.speedFan({ ...payload, display_zero_speed_fans: false });
    assert.ok(!hidden.includes('Fan2') && hidden.includes('CPU Fan'));
    assert.equal(renderers.speedFan({ ...payload, fans: false }), '');
});

test('fans of a real capture with repeated labels are all listed', () => {
    const html = renderers.speedFan(realPayload);
    assert.equal((html.match(/>Processor Fan<\/td>/g) || []).length, 2, 'both processor fans');
    assert.ok(html.includes('995 RPM') && html.includes('994 RPM'));
    assert.ok(html.includes('>Other Fan</td>') && html.includes('600 RPM'));
});

test('fans without readings render a placeholder row', () => {
    assert.ok(renderers.speedFan(enabled({ chip: { Adapter: 'x' } })).includes('<tr><td>N/A</td></tr>'));
});

// ---- Every fixture -------------------------------------------------------------
// Every NN-*.json fixture goes through the Perl collector and then every renderer.
test('fixtures are available', () => {
    assert.ok(allPayloads.length >= 11, allPayloads.join(', '));
});

for (const name of allPayloads) {
    test(`${name}: every renderer handles the collector payload`, () => {
        const real = loadPayload(name);
        const chips = Object.keys(real.enhanced_sensors);
        const html = {
            cpu: renderCpu(real), ram: renderers.thermalRam(real), hdd: renderers.thermalHdd(real),
            nvme: renderers.thermalNvme(real), other: renderers.otherThermals(real), fans: renderers.speedFan(real),
        };
        for (const [kind, output] of Object.entries(html)) {
            assert.equal(typeof output, 'string', kind);
            assert.ok(!/undefined|NaN|\[object/.test(output), `${kind} output has no stray values: ${output.slice(0, 200)}`);
        }
        if (chips.some(chip => /^(coretemp-isa-|k10temp-pci-)/.test(chip))) {
            assert.notEqual(html.cpu, 'N/A', 'CPU thermal state is shown');
        }
        const drives = chips.filter(chip => chip.startsWith('drivetemp-scsi-'));
        if (drives.length) {
            assert.ok((html.hdd.match(/<tr>/g) || []).length <= drives.length);
            assert.ok(html.hdd.includes('Test SSD'), 'drive rows carry the model');
        }
        if (chips.some(chip => chip.startsWith('nvme-pci-'))) {
            assert.ok(html.nvme.includes('Test NVMe&nbsp;(NVME456)'));
        }
        if (chips.some(chip => /^DIMM\d+$/.test(chip))) {
            assert.notEqual(html.ram, 'N/A', 'DIMM temperatures are shown');
        }
    });
}

test('SODIMM temperatures are listed as DIMMs and not as other temperatures', () => {
    const ram = renderers.thermalRam(realPayload);
    for (const [slot, value] of [[3, 25], [4, 33], [5, 33], [6, 24]]) {
        assert.ok(ram.includes(`${slot}:&nbsp;<span style="">${value}.0&deg;C</span>`), `slot ${slot}`);
    }
    assert.ok(ram.indexOf('3:&nbsp;') < ram.indexOf('6:&nbsp;'), 'slots are in order');
    const other = renderers.otherThermals(realPayload);
    assert.ok(other.includes('>dell_smm-isa-0000<'), 'the chip is still listed for its other sensors');
    assert.ok(!other.includes('SODIMM'), 'its SODIMM sensors are not repeated here');
    assert.equal((other.split('CPU:&nbsp;').length - 1), 2, 'both CPU sensors remain');

    const single = renderers.thermalRam(loadPayload('04-dell-smm-sodimm.json'));
    assert.ok(single.includes('6:&nbsp;<span style="">38.0&deg;C</span>'));
    assert.equal(renderers.thermalRam({ ...realPayload, ram: false }), '');
});

test('sensors -J capture (02): CPU, DDR5, NVMe, other temperatures and fans', () => {
    const real = loadPayload('02-intel-it8620-ddr5-nvme.json');
    const [group] = context.getCpuThermalGroups(real);
    assert.equal(group.label, 'Package 0');
    assert.equal(group.selected.length, 8, 'all eight cores');
    const cpu = renderCpu(real);
    assert.ok(cpu.includes('Min: <span style="">47.0&deg;C</span>'));
    assert.ok(cpu.includes('Max: <span style="">52.0&deg;C</span>'));
    assert.ok(cpu.includes('(8 sensors)'));

    assert.ok(renderers.thermalRam(real).includes('1:&nbsp;<span style="">43.5&deg;C</span>'));
    assert.ok(renderers.thermalNvme(real).includes(`${(41.85).toFixed(1)}&deg;C`));

    const other = renderers.otherThermals(real);
    assert.ok(other.includes('>it8620-isa-0a20<') && other.includes('>acpitz-acpi-0<'));
    assert.ok(other.includes(`<span style="${YELLOW}">38.0&deg;C</span>`),
        'the live thermistor is shown; its reported max of -23 puts it over its limit');
    const row = other.split('<tr>').find(part => part.includes('>it8620-isa-0a20<'));
    assert.ok(row.includes('38.0&deg;C') && !/temp\d+:/.test(row), 'the live thermistor is listed without a generic label');
    assert.equal((row.match(/&deg;C/g) || []).length, 1, 'only the live reading of the chip is listed');
    assert.ok(!row.includes('-128'), 'disconnected (-128) and zero readings of the same chip are hidden');

    const fans = renderers.speedFan(real);
    assert.ok(fans.includes('>Fan2</td>') && fans.includes('1347 RPM'));
    assert.ok(fans.includes('>Fan3</td>') && fans.includes('0 RPM'), 'the stopped fan is listed when zero speeds are enabled');
    assert.ok(!fans.includes('pwm'), 'PWM duty cycles are not fans');
    assert.ok(!renderers.speedFan({ ...real, display_zero_speed_fans: false }).includes('Fan3'));
});

test('real AMD capture: Tctl is the only CPU sensor and DDR5 is listed', () => {
    const real = loadPayload('09-amd-ddr5-nvme.json');
    const [group] = context.getCpuThermalGroups(real);
    assert.deepEqual(plain(group.selected.map(row => row.label)), ['Tctl']);
    assert.ok(renderCpu(real).includes('(1 sensor)'));
    assert.ok(renderers.thermalRam(real).includes('1:&nbsp;<span style="">48.5&deg;C</span>'));
    assert.ok(renderers.otherThermals(real).includes('>r8169_0_400:00-mdio-0<'), 'the NIC PHY is an other temperature');
    assert.ok(renderers.otherThermals(real).includes('>acpitz-acpi-0<'));
});

test('real Raspberry Pi 5 capture: SoC, RP1, NVMe controllers and the fan', () => {
    const real = loadPayload('10-raspberry-pi5-2-nvme.json');
    const [group] = context.getCpuThermalGroups(real);
    assert.equal(group.id, 'cpu_thermal-virtual-0');
    assert.deepEqual(plain(group.selected.map(row => row.value)), [45.2]);
    const cpu = renderCpu(real);
    assert.ok(cpu.includes('45.2&deg;C') && cpu.includes('(1 sensor)'), 'the SoC temperature the issue reported missing is shown');

    const other = renderers.otherThermals(real);
    assert.ok(other.includes('>rp1_adc-isa-0000<'), `the RP1 chip is listed: ${other}`);
    assert.ok(other.includes('<span style="">52.0&deg;C</span>') && !other.includes('temp1:'));
    assert.ok(!other.includes('>hidpp_battery') && !other.includes('>rpi_volt'), 'voltage-only chips are not temperatures');
    assert.ok(!other.includes('in1'), 'RP1 voltages are not temperatures');

    const nvme = renderers.thermalNvme(real);
    assert.equal((nvme.match(/<tr>/g) || []).length, 2, 'both NVMe drives');
    assert.ok(nvme.includes('32.9&deg;C') && nvme.includes('29.9&deg;C'), 'Composite, not the extra sensors');
    assert.ok(nvme.indexOf('29.9') < nvme.indexOf('32.9'), 'nvme-pci-10400 sorts before nvme-pci-10600');

    assert.ok(renderers.speedFan(real).includes('>Fan1</td>') && renderers.speedFan(real).includes('0 RPM'));
    assert.ok(!renderers.speedFan({ ...real, display_zero_speed_fans: false }).includes('Fan1'));
});

test('real capture with many drives lists each readable drive in order', () => {
    const real = loadPayload('11-nct6779-14-drives.json');
    const html = renderers.thermalHdd(real);
    const drives = Object.keys(real.enhanced_sensors).filter(chip => chip.startsWith('drivetemp-scsi-'));
    assert.equal(drives.length, 14);
    assert.equal((html.match(/<tr>/g) || []).length, 14);
    assert.ok(html.includes('1. Test SSD&nbsp;(SER123)'));
    const positions = Array.from({ length: 14 }, (_, i) => html.indexOf(`>${i + 1}. Test SSD`));
    assert.ok(positions.every(position => position >= 0), 'rows are numbered 1 to 14');
    assert.deepEqual(positions, [...positions].sort((a, b) => a - b), 'numbers ascend down the table');
});
