const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(process.env.PVE_MANAGER_JS || '/usr/share/pve-manager/js/pvemanagerlib.js', 'utf8');
const encode = value => String(value ?? '').replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[c]);

function setup() {
    const definitions = {};
    const timers = [];
    const context = {
        console, gettext: text => text, Map, Set, Promise, Date,
        setTimeout: (callback, delay) => { timers.push({ callback, delay }); },
        PVE: { mod: {}, Utils: new Proxy({}, { get: () => () => {} }) },
        Proxmox: { Utils: new Proxy({
            IP64_match: { test: value => !!net.isIP(value) },
        }, { get: (target, key) => target[key] || (() => {}) }) },
        Ext: {
            define(name, definition) {
                definitions[name] = definition;
                if (name === 'PVE.Parser') {
                    context.PVE.Parser = definition.statics;
                } else if (name === 'PVE.mod.GuestNetworkInfo') {
                    context.PVE.mod.GuestNetworkInfo = definition;
                }
            },
            htmlEncode: encode,
            apply: Object.assign,
            isDefined: value => value !== undefined,
            isNumeric: value => value !== '' && Number.isFinite(Number(value)),
            Array: { each: (values, fn) => values.forEach(fn) },
            Object: { each: (object, fn) => Object.entries(object).forEach(([key, value]) => fn(key, value)) },
        },
    };
    for (const startName of [
        'PVE.Parser', 'PVE.mod.GuestNetworkInfo', 'PVE.data.ResourceStore',
        'PVE.form.GlobalSearchField', 'PVE.grid.ResourceGrid',
    ]) {
        const start = source.indexOf(`Ext.define('${startName}',`);
        const end = source.indexOf('\n});', start) + 4;
        assert.ok(start >= 0 && end > start, `${startName} definition exists`);
        vm.runInNewContext(source.slice(start, end), context);
    }
    return { context, definitions, timers, info: context.PVE.mod.GuestNetworkInfo };
}

function record(data) {
    return {
        data,
        get: key => data[key],
        set: values => Object.assign(data, values),
    };
}

function store(records) {
    const events = [];
    return {
        records, events,
        getById: id => records.find(rec => rec.data.id === id),
        each: fn => records.forEach(fn),
        fireEvent: (...args) => events.push(args),
    };
}

const guest = (extra = {}) => ({ id: 'qemu/100', node: 'node1', type: 'qemu', vmid: 100, status: 'running', ...extra });
const nic = (name, mac, ...ips) => ({
    name, 'hardware-address': mac, 'ip-addresses': ips.map(ip => ({ 'ip-address': ip })),
});

test('QEMU: two IP families, all interfaces, deduplicated MACs, hostname and OS', async () => {
    const { info } = setup();
    const calls = [];
    info.request = async url => {
        calls.push(url);
        if (url.endsWith('/config')) {
            return { data: { agent: 'enabled=1,fstrim_cloned_disks=1',
                net0: 'virtio=AA:BB:CC:DD:EE:01,bridge=vmbr0',
                net1: 'virtio=AA:BB:CC:DD:EE:02,bridge=vmbr0' } };
        }
        if (url.endsWith('/network-get-interfaces')) {
            return { data: { result: [
                nic('lo', '00:00:00:00:00:00', '127.0.0.1', '::1'),
                nic('eth0', 'aa:bb:cc:dd:ee:01', '192.0.2.10', '2001:db8::10', 'fe80::1'),
                nic('eth1', 'AA:BB:CC:DD:EE:02', '192.0.2.2'),
                nic('docker0', '02:42:00:00:00:01', '172.17.0.1'),
                nic('veth123', '02:42:00:00:00:02', '172.18.0.1', 'fd00::123'),
            ] } };
        }
        return { data: { result: url.endsWith('/get-host-name')
            ? { 'host-name': 'guest.example.test' } : { 'pretty-name': 'Debian GNU/Linux 13' } } };
    };
    const data = await info.collect({ guest: guest() });
    assert.equal(data.guest_ips, '192.0.2.2, 192.0.2.10, 2001:db8::10, fe80::1');
    assert.equal(data.guest_macs, 'AA:BB:CC:DD:EE:01, AA:BB:CC:DD:EE:02');
    assert.equal(data.guest_hostname, 'guest.example.test');
    assert.equal(data.guest_os, 'Debian GNU/Linux 13');
    assert.equal(data.guest_info_status, 'QEMU Guest Agent');
    assert.equal(calls.length, 4);
});

test('QEMU: disabled agent, stopped guest and template do not query the agent', async () => {
    for (const [extra, agent, expected] of [
        [{}, '0', 'Guest Agent disabled'],
        [{ status: 'stopped' }, '1', 'Guest not running'],
        [{ template: 1 }, '1', 'Template'],
    ]) {
        const { info } = setup();
        let calls = 0;
        info.request = async () => { calls++; return { data: { agent, net0: 'virtio=AA:BB:CC:DD:EE:01' } }; };
        const data = await info.collect({ guest: guest(extra) });
        assert.equal(calls, 1);
        assert.equal(data.guest_ips, '');
        assert.equal(data.guest_macs, 'AA:BB:CC:DD:EE:01');
        assert.equal(data.guest_info_status, expected);
    }
});

test('QEMU: permissions, absent agent and unsupported commands surface errors without invented values', async () => {
    const { info } = setup();
    info.request = async url => url.endsWith('/config')
        ? { data: { agent: '1', net0: 'virtio=AA:BB:CC:DD:EE:01' } }
        : { error: '403 permission denied' };
    const data = await info.collect({ guest: guest() });
    assert.equal(data.guest_ips, '');
    assert.equal(data.guest_hostname, '');
    assert.equal(data.guest_os, '');
    assert.equal(data.guest_macs, 'AA:BB:CC:DD:EE:01');
    assert.match(data.guest_info_status, /network-get-interfaces: 403/);
    assert.match(data.guest_info_status, /get-host-name: 403/);
    info.request = async () => ({ error: '403 permission denied' });
    assert.match((await info.collect({ guest: guest() })).guest_info_status, /Configuration: 403/);
});

test('LXC: stopped config addresses and running DHCP/SLAAC addresses, with configured MAC fallback', async () => {
    const { info } = setup();
    info.request = async url => url.endsWith('/config')
        ? { data: { net0: 'name=eth0,hwaddr=AA:BB:CC:DD:EE:01,ip=192.0.2.1/24,ip6=2001:db8::1/64,type=veth' } }
        : { data: [nic('lo', '00:00:00:00:00:00', '127.0.0.1'),
            nic('eth0', 'aa:bb:cc:dd:ee:01', '192.0.2.2', '2001:db8::2', 'fe80::1'),
            nic('docker0', '02:42:00:00:00:01', '172.17.0.1')] };
    const ct = guest({ type: 'lxc', id: 'lxc/101', vmid: 101, status: 'stopped' });
    assert.equal((await info.collect({ guest: ct })).guest_ips, '192.0.2.1, 2001:db8::1');
    const running = await info.collect({ guest: { ...ct, status: 'running' } });
    assert.equal(running.guest_ips, '192.0.2.2, 2001:db8::2, fe80::1');
    assert.equal(running.guest_macs, 'AA:BB:CC:DD:EE:01');
    assert.equal(running.guest_hostname, '');
    info.request = async url => url.endsWith('/config')
        ? { data: { net0: 'name=eth0,ip=dhcp,ip6=auto,type=veth' } }
        : { error: 'interfaces unavailable' };
    const unavailable = await info.collect({ guest: { ...ct, status: 'running' } });
    assert.equal(unavailable.guest_ips, '');
    assert.match(unavailable.guest_info_status, /Network: interfaces unavailable/);
});

test('IP sorting is numeric across IPv4, compressed IPv6, embedded IPv4 and multiple addresses', () => {
    const { info } = setup();
    const sorted = ['2001:db8::10', '', '192.0.2.10', '2001:db8::2', '192.0.2.2'].sort((a, b) =>
        info.sortIPs(a).localeCompare(info.sortIPs(b)));
    assert.deepEqual(sorted, ['192.0.2.2', '192.0.2.10', '2001:db8::2', '2001:db8::10', '']);
    assert.equal(info.ipKey('2001:db8::2'), info.ipKey('2001:0db8:0:0:0:0:0:2'));
    assert.equal(info.ipKey('::ffff:192.0.2.2'), info.ipKey('::ffff:c000:202'));
    assert.ok(info.sortIPs('192.0.2.2, 2001:db8::1') < info.sortIPs('192.0.2.10'));
    const ips = new Set();
    for (const ip of ['dhcp', 'auto', '127.0.0.2', '::1', '0.0.0.0', '::', '<script>', 'fe80::1%eth0/64']) {
        info.addIP(ips, ip);
    }
    assert.deepEqual([...ips], ['fe80::1%eth0']);
});

test('only configured MACs are used, including when configuration is unavailable', () => {
    const { info } = setup();
    const ips = new Set();
    const macs = new Set();
    const interfaces = [nic('eth0', 'aa:bb:cc:dd:ee:01', '192.0.2.2', 'fd00::2')];
    info.liveNetwork(interfaces, ips, macs);
    assert.equal(ips.size, 0);
    assert.equal(macs.size, 0);
    macs.add('AA:BB:CC:DD:EE:01');
    info.liveNetwork(interfaces, ips, macs);
    assert.deepEqual([...ips], ['192.0.2.2', 'fd00::2']);
});

test('cell and status tooltip content is HTML encoded', () => {
    const { info } = setup();
    const metadata = {};
    assert.equal(info.renderList('<script>', metadata, record({ guest_info_status: '" onmouseover="evil' })), '&lt;script&gt;');
    assert.equal(metadata.tdAttr, 'data-qtip="&lt;script&gt; - &quot; onmouseover=&quot;evil"');
    assert.equal(info.renderText('<hostname>', metadata), '&lt;hostname&gt;');
    assert.equal(metadata.tdAttr, 'data-qtip="&lt;hostname&gt;"');
});

test('shared columns are independent configs and cache copying clears absent values', () => {
    const { info } = setup();
    const first = info.columns();
    const second = info.columns();
    first[0].hidden = true;
    assert.equal(second[0].hidden, undefined);
    assert.ok(second.every(column => column.sortable));
    const data = guest();
    info.cache.set(data.id, { signature: info.signature(data), values: { guest_ips: '192.0.2.2' } });
    const rec = record({ ...data, guest_hostname: 'stale' });
    info.copyCached(rec);
    assert.equal(rec.get('guest_ips'), '192.0.2.2');
    assert.equal(rec.get('guest_hostname'), '');
});

test('automatic sizing waits for data, caps widths and preserves manual resizing', () => {
    const { info } = setup();
    const events = {};
    const columns = [
        ['guest_ips', 600], ['guest_macs', 150], ['guest_hostname', 70],
        ['guest_os', 500], ['name', 400], ['vmid', 45], ['hidden', 600],
    ].map(([dataIndex, contentWidth]) => ({
        dataIndex, width: 200, sizes: 0,
        autoSize() { this.sizes++; this.width = contentWidth; },
        getWidth() { return this.width; },
        setWidth(width) {
            this.width = width;
            events.columnresize(null, this);
        },
    }));
    columns[6].hidden = true;
    let visible = true;
    let count = 0;
    const grid = {
        headerCt: {}, getView: () => ({}), isVisible: () => visible,
        getStore: () => ({ getCount: () => count }),
        getColumnManager: () => ({ getColumns: () => columns }),
        mon: (target, event, fn) => { events[event] = fn; },
        on: config => Object.assign(events, config),
    };
    info.autoSizeColumns(grid);
    events.refresh();
    assert.ok(columns.every(column => column.sizes === 0), 'empty grid is not sized');
    count = 2;
    info.active = 1;
    events.refresh();
    assert.ok(columns.every(column => column.sizes === 0), 'waits for collection');
    info.active = 0;
    visible = false;
    events.refresh();
    assert.ok(columns.every(column => column.sizes === 0), 'hidden grid is not measured');
    visible = true;
    grid.headerCt.resizer = { dragHd: columns[1] };
    columns[1].setWidth(175);
    grid.headerCt.resizer.dragHd = null;
    events.show();
    assert.deepEqual(columns.map(column => column.width), [360, 175, 70, 260, 300, 60, 200]);
    assert.equal(columns[4].sizes, 1, 'standard columns are also sized');
    assert.equal(columns[6].sizes, 0, 'hidden columns remain unchanged');
    assert.equal(columns[1].sizes, 0, 'manual resize is respected even before collection completes');
    columns[0].setWidth(420);
    events.refresh();
    assert.equal(columns[0].width, 420, 'later refreshes do not override manual widths');
    assert.equal(columns[0].sizes, 1);
});

test('publishing batches notifications within 100ms without delaying data or losing later updates', () => {
    const { info, timers } = setup();
    const records = [record(guest()), record(guest({ id: 'qemu/101', vmid: 101 }))];
    info.store = store(records);
    const entries = records.map(rec => {
        const entry = { guest: rec.data, signature: info.signature(rec.data), loading: true };
        info.cache.set(rec.data.id, entry);
        return entry;
    });
    entries.forEach((entry, i) => info.publish(entry, { guest_ips: `192.0.2.${i + 1}` }));
    assert.equal(records[0].get('guest_ips'), '192.0.2.1');
    assert.equal(records[1].get('guest_ips'), '192.0.2.2');
    assert.equal(info.store.events.length, 0);
    assert.equal(timers.length, 1);
    assert.equal(timers[0].delay, 100);
    timers.shift().callback();
    assert.equal(info.store.events.length, 1);
    info.publish(entries[0], { guest_ips: '192.0.2.3' });
    assert.equal(timers.length, 1);
    timers.shift().callback();
    assert.equal(info.store.events.length, 2);
    info.cache.delete(entries[0].guest.id);
    info.publish(entries[0], { guest_ips: '192.0.2.99' });
    assert.equal(timers.length, 0, 'stale results do not schedule notifications');
});

test('resource field definitions include sortable IPs and preserve cached values on API reload', () => {
    const { info, definitions } = setup();
    const events = {};
    const me = { on: (event, fn) => { events[event] = fn; }, clearCache() {}, callParent: args => { me.config = args[0]; } };
    definitions['PVE.data.ResourceStore'].constructor.call(me, {});
    const fields = definitions.PVEResources.fields;
    assert.ok(fields.filter(field => info.fields.includes(field.name)).every(field => field.persist === false),
        'read-only guest information must not create dirty-cell triangles');
    assert.equal(fields.find(field => field.name === 'name').persist, undefined);
    assert.equal(fields.find(field => field.name === 'guest_ips').sortType, info.sortIPs);
    const columns = me.config.defaultColumns();
    for (const field of info.fields) {
        assert.ok(columns.some(column => column.dataIndex === field));
    }
    assert.ok(columns.find(column => column.dataIndex === 'guest_ips').sortable);
    const metadata = {};
    assert.equal(columns.find(column => column.dataIndex === 'guest_macs').renderer(
        'AA:BB:CC:DD:EE:01', metadata, record({ guest_info_status: 'Guest not running' }),
    ), 'AA:BB:CC:DD:EE:01');
    assert.equal(metadata.tdAttr, undefined, 'configured MACs have no guest runtime status tooltip');
    assert.equal(events.load, info.refresh);
    const data = guest();
    info.cache.set(data.id, { signature: info.signature(data), values: { guest_ips: '192.0.2.2' } });
    assert.equal(fields.find(field => field.name === 'guest_ips').convert(null, record(data)), '192.0.2.2');
    assert.equal(fields.find(field => field.name === 'guest_ips').convert(null, record({ ...data, node: 'node2' })), '');
});

test('global search matches IP, IPv6, MAC, hostname and OS case-insensitively', () => {
    const { definitions } = setup();
    const search = definitions['PVE.form.GlobalSearchField'];
    const data = { ...guest(), guest_ips: '192.0.2.2, 2001:db8::2', guest_macs: 'AA:BB:CC:DD:EE:01',
        guest_hostname: 'guest.example.test', guest_os: 'Debian GNU/Linux 13' };
    for (const query of ['192.0.2', '2001:db8', 'aa:bb:cc', 'guest.example', 'debian']) {
        assert.equal(search.customFilter.call({ filterVal: query }, record(data)), true);
    }
    assert.equal(search.customFilter.call({ filterVal: 'not-present' }, record(data)), false);
    assert.ok(search.grid.columns.some(column => column.dataIndex === 'guest_ips' && column.sortable));
    assert.ok(search.grid.columns.some(column => column.dataIndex === 'guest_macs'));
    const metadata = {};
    search.grid.columns.find(column => column.dataIndex === 'guest_macs').renderer(
        'AA:BB:CC:DD:EE:01', metadata, record({ guest_info_status: 'Guest not running' }),
    );
    assert.equal(metadata.tdAttr, undefined);
});

test('collection concurrency is capped, repeated polls are cached, and migration invalidates results', async () => {
    const { info } = setup();
    const records = Array.from({ length: 10 }, (_, i) => record(guest({ id: `qemu/${i}`, vmid: i })));
    const resources = store(records);
    const pending = [];
    let calls = 0;
    info.collect = entry => new Promise(resolve => { calls++; pending.push({ entry, resolve }); });
    info.refresh(resources, records, true);
    assert.equal(info.active, 4);
    assert.equal(calls, 4);
    info.refresh(resources, records, true);
    assert.equal(info.queue.length, 6);
    records[0].data.node = 'node2';
    const old = pending.shift();
    old.resolve({ guest_ips: '192.0.2.99' });
    await new Promise(resolve => setImmediate(resolve));
    assert.notEqual(records[0].data.guest_ips, '192.0.2.99');
    while (pending.length) {
        pending.shift().resolve({ guest_ips: '192.0.2.2' });
        await new Promise(resolve => setImmediate(resolve));
    }
    info.refresh(resources, records, true);
    assert.equal(calls, 11, 'only migrated guest is refreshed within 60 seconds');
    pending.shift().resolve({ guest_ips: '192.0.2.3' });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(records[0].data.guest_ips, '192.0.2.3');
    info.refresh(resources, records, true);
    assert.equal(calls, 11);
    resources.records.splice(0, 1);
    info.refresh(resources, records, true);
    assert.equal(info.cache.has('qemu/0'), false);
});

test('resource-grid search uses canonical data rather than stale tree node fields', () => {
    const { context, definitions } = setup();
    const rec = record({ ...guest(), guest_ips: '192.0.2.2', guest_macs: 'AA:BB:CC:DD:EE:01' });
    const resources = { data: { get: () => rec }, defaultColumns: () => [], fieldNames: Object.keys(rec.data) };
    context.PVE.data = { ResourceStore: resources };
    let rows = [];
    const gridStore = {
        data: { get: id => rows.find(row => row.data.id === id) },
        suspendEvents() {}, resumeEvents() {}, sort() {}, fireEvent() {},
        each: fn => rows.forEach(fn),
        add: records => { rows.push(...records); },
        remove: records => { rows = rows.filter(row => !records.includes(row)); },
    };
    context.Ext.create = () => gridStore;
    context.PVE.mod.GuestNetworkInfo.autoSizeColumns = () => {};
    const events = {};
    let heading = '';
    const me = { pveSelNode: { childNodes: [{ data: { id: rec.data.id } }] }, callParent() {},
        down: () => ({ setText: text => { heading = text; } }),
        mon: (target, event, fn) => { events[event] = fn; } };
    definitions['PVE.grid.ResourceGrid'].initComponent.call(me);
    const search = me.tbar.find(item => item.xtype === 'textfield').listeners.keyup;
    search({ getValue: () => 'aa:bb:cc' });
    assert.equal(rows.length, 1);
    assert.equal(heading, 'VMs: 1 | Search matches: 1 / 1');
    search({ getValue: () => '192.0.2.2' });
    assert.equal(rows.length, 1);
    search({ getValue: () => 'not-present' });
    assert.equal(rows.length, 0);
    assert.equal(heading, 'VMs: 1 | Search matches: 0 / 1');
    search({ getValue: () => '' });
    assert.equal(heading, 'VMs: 1 | Search matches: 1 / 1');
    const ct = record(guest({ id: 'lxc/101', type: 'lxc', vmid: 101 }));
    resources.data.get = id => id === ct.data.id ? ct : rec;
    me.pveSelNode.childNodes.push({ data: { id: ct.data.id } }, { data: { id: rec.data.id } });
    search({ getValue: () => 'qemu' });
    assert.equal(heading, 'CTs: 1 | VMs: 1 | Search matches: 1 / 2', 'duplicate tree paths are counted once');
    me.viewFilter = { filterfn: child => child.data.id !== ct.data.id };
    search({ getValue: () => '' });
    assert.equal(heading, 'VMs: 1 | Search matches: 1 / 1', 'view filter limits totals');
    assert.equal(typeof events.guestinfochange, 'function');
});
