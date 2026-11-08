const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const source = fs.readFileSync(
    `${__dirname}/../../src/modules/node_info/files/PveMods_pvemanagerlib.js`, 'utf8',
);
const start = source.indexOf("Ext.define('PVE.mod.SummaryColumns'");
const end = source.indexOf("Ext.define('PVE.node.Summary'", start);

function fixture(count = 6, width = 1800) {
    let mode = 'auto';
    let update;
    let suspended = 0;
    const Ext = {
        define: (name, definition) => { update = definition.update; },
        state: { Manager: { get: () => mode } },
        String: { htmlDecode: text => text.replace(/&amp;/g, '&') },
        suspendLayouts: () => { suspended++; },
        resumeLayouts: () => {
            suspended--;
            update(container);
        },
    };
    new Function('Ext', source.slice(start, end))(Ext);

    function makeContainer(config = {}) {
        return {
            ...config,
            items: { items: [] },
            add(item) {
                if (item.xtype === 'container' && !item.items) {
                    item = makeContainer(item);
                }
                assert.equal(item.ownerCt, undefined);
                item.ownerCt = this;
                this.items.items.push(item);
                return item;
            },
            remove(item, destroy) {
                const index = this.items.items.indexOf(item);
                assert.ok(index >= 0);
                this.items.items.splice(index, 1);
                delete item.ownerCt;
                if (destroy) {
                    assert.equal(item.items.items.length, 0);
                    item.destroyed = true;
                }
            },
            getWidth: () => width,
            updateLayout() {},
        };
    }
    const container = makeContainer();
    const items = Array.from({ length: count }, (_, id) => container.add({
        id, title: `Chart ${id}`, columnWidth: 1, padding: 5, minHeight: 360,
    }));
    return {
        container, items,
        update: () => {
            update(container);
            assert.equal(suspended, 0);
            assert.equal(container.updatingSummaryColumns, false);
        },
        setMode: value => { mode = value; },
        setWidth: value => { width = value; },
        order: () => container.summaryColumns.map(column => column.items.items.map(item => item.id)),
    };
}

test('wide columns use independent anchor stacks and retain chart sizing', () => {
    const f = fixture();
    f.update();
    assert.deepEqual(f.order(), [[0, 2, 4], [1, 3, 5]]);
    f.container.summaryColumns.forEach(column => {
        assert.equal(column.layout, 'anchor');
        assert.equal(column.columnWidth, 0.5);
        assert.equal(column.padding, 0);
    });
    f.items.forEach(item => {
        assert.equal(item.anchor, '100%');
        assert.equal(item.columnWidth, undefined);
        assert.equal(item.padding, 5);
        assert.equal(item.minHeight, 360);
    });
});

test('resizing preserves instances and original order across Auto/1/2/3', () => {
    const f = fixture();
    f.update();
    f.setWidth(1000);
    f.update();
    assert.deepEqual(f.order(), [[0, 1, 2, 3, 4, 5]]);
    f.setWidth(3000);
    f.update();
    assert.deepEqual(f.order(), [[0, 3], [1, 4], [2, 5]]);
    for (const mode of ['1', '2', '3']) {
        f.setMode(mode);
        f.update();
        assert.equal(f.container.summaryColumns.length, Number(mode));
        f.items.forEach(item => assert.equal(item.destroyed, undefined));
    }
});

test('new GPU charts join an existing column even without a factor change', () => {
    const f = fixture(5);
    f.update();
    const columns = f.container.summaryColumns;
    const gpu = f.container.add({ id: 5, title: 'Chart 5', columnWidth: 0.5 });
    f.update();
    assert.equal(f.container.summaryColumns, columns);
    assert.deepEqual(f.order(), [[0, 2, 4], [1, 3, 5]]);
    assert.equal(gpu.ownerCt, columns[1]);
    f.update();
    assert.equal(f.container.summaryItems.length, 6);
    assert.deepEqual(f.order(), [[0, 2, 4], [1, 3, 5]]);
});

test('unchanged layout does not recreate columns or reparent charts', () => {
    const f = fixture();
    f.update();
    const columns = f.container.summaryColumns;
    const owners = f.items.map(item => item.ownerCt);
    f.update();
    assert.equal(f.container.summaryColumns, columns);
    f.items.forEach((item, index) => assert.equal(item.ownerCt, owners[index]));
});

test('graphs sort alphabetically while the summary stays first', () => {
    const f = fixture();
    const titles = ['Summary', 'Network Traffic', 'Memory', 'IO Pressure Stall', 'GPU: Intel', 'CPU'];
    f.items.forEach((item, index) => { item.title = titles[index]; });
    f.update();
    assert.deepEqual(f.order(), [[0, 4, 2], [5, 3, 1]]);
    f.container.add({ id: 6, title: 'GPU: AMD' });
    f.update();
    assert.deepEqual(f.order(), [[0, 6, 3, 1], [5, 4, 2]]);
    f.setMode('1');
    f.update();
    assert.deepEqual(f.order(), [[0, 5, 6, 4, 3, 2, 1]]);
});

test('sort compares decoded titles and orders device numbers naturally', () => {
    const f = fixture(4);
    ['Summary', 'GPU: Intel 10', 'GPU: Intel 2', 'GPU: A&amp;B'].forEach((title, index) => {
        f.items[index].title = title;
    });
    f.setMode('1');
    f.update();
    assert.deepEqual(f.order(), [[0, 3, 2, 1]]);
});

test('column count is bounded by item count and invalid preferences use one', () => {
    const f = fixture(2);
    for (const mode of ['3', '99', '0', '-1', 'invalid']) {
        f.setMode(mode);
        f.update();
        assert.equal(f.container.summaryColumns.length, mode === '3' || mode === '99' ? 2 : 1);
    }
});

test('empty containers are ignored safely', () => {
    const f = fixture(0);
    assert.doesNotThrow(() => {
        // No columns need creating, so the update guard remains unset.
        const Ext = {
            define: (name, definition) => definition.update(f.container),
            state: { Manager: { get: () => 'auto' } },
        };
        new Function('Ext', source.slice(start, end))(Ext);
    });
    assert.equal(f.container.items.items.length, 0);
});
