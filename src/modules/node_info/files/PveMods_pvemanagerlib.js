Ext.define('PVE.mod.TempHelper', {
	//singleton: true,

	requires: ['Ext.util.Format'],

	statics: {
		CELSIUS: 0,
		FAHRENHEIT: 1
	},

	srcUnit: null,
	dstUnit: null,

	isValidUnit: function (unit) {
		return (
			Ext.isNumber(unit) && (unit === this.self.CELSIUS || unit === this.self.FAHRENHEIT)
		);
	},

	constructor: function (config) {
		this.srcUnit = config && this.isValidUnit(config.srcUnit) ? config.srcUnit : this.self.CELSIUS;
		this.dstUnit = config && this.isValidUnit(config.dstUnit) ? config.dstUnit : this.self.CELSIUS;
	},

	toFahrenheit: function (tempCelsius) {
		return Ext.isNumber(tempCelsius)
			? tempCelsius * 9 / 5 + 32
			: NaN;
	},

	toCelsius: function (tempFahrenheit) {
		return Ext.isNumber(tempFahrenheit)
			? (tempFahrenheit - 32) * 5 / 9
			: NaN;
	},

	getTemp: function (value) {
		if (this.srcUnit !== this.dstUnit) {
			switch (this.srcUnit) {
				case this.self.CELSIUS:
					switch (this.dstUnit) {
						case this.self.FAHRENHEIT:
							return this.toFahrenheit(value);

						default:
							Ext.raise({
								msg:
									'Unsupported destination temperature unit: ' + this.dstUnit,
							});
					}
				case this.self.FAHRENHEIT:
					switch (this.dstUnit) {
						case this.self.CELSIUS:
							return this.toCelsius(value);

						default:
							Ext.raise({
								msg:
									'Unsupported destination temperature unit: ' + this.dstUnit,
							});
					}
				default:
					Ext.raise({
						msg: 'Unsupported source temperature unit: ' + this.srcUnit,
					});
			}
		} else {
			return value;
		}
	},

	getUnit: function(plainText) {
		switch (this.dstUnit) {
			case this.self.CELSIUS:
				return plainText !== true ? '&deg;C' : '\'C';

			case this.self.FAHRENHEIT:
				return plainText !== true ? '&deg;F' : '\'F';

			default:
				Ext.raise({
					msg: 'Unsupported destination temperature unit: ' + this.srcUnit,
				});
		}
	},
});
function getSensorLabel(feature, fallback) {
    return feature && typeof feature.label === 'string' ? feature.label : fallback;
}

function getSensorValue(feature, subfeature) {
    if (!feature || typeof feature !== 'object') {
        return NaN;
    }

    let reading = feature[subfeature];
    if (reading === undefined) {
        const legacyKey = Object.keys(feature).find(key => key.endsWith(`_${subfeature}`));
        if (legacyKey) {
            reading = feature[legacyKey];
        }
    }
    if (reading && typeof reading === 'object') {
        reading = reading.value;
    }
    if (reading === null || reading === undefined || typeof reading === 'boolean'
        || (typeof reading === 'string' && reading.trim() === '')) {
        return NaN;
    }
    const value = Number(reading);
    return Number.isFinite(value) ? value : NaN;
}

function getTemperatureFeature(sensorGroup, preferredLabel) {
    if (!sensorGroup || typeof sensorGroup !== 'object') {
        return null;
    }
    if (sensorGroup[preferredLabel] && typeof sensorGroup[preferredLabel] === 'object') {
        return sensorGroup[preferredLabel];
    }

    const featureKeys = Object.keys(sensorGroup).filter(key => /^temp\d+$/.test(key));
    const matchingKey = featureKeys.find(key => getSensorLabel(sensorGroup[key], key) === preferredLabel);
    return sensorGroup[matchingKey || featureKeys[0]] || null;
}

function getSensorPayload(sensorInfo) {
    const payload = sensorInfo?.enhanced_sensors;
    return payload && typeof payload === 'object' ? payload : {};
}

function isSensorEnabled(sensorInfo, sensorType) {
    return !!sensorInfo
        && sensorInfo.disabled !== true
        && sensorInfo[sensorType] === true;
}

function getModMetricState(itemId, payload) {
    if (!payload || typeof payload !== 'object') {
        return 'pending';
    }
    const sensors = {
        thermalCpu: 'cpu', thermalRam: 'ram', thermalHdd: 'hdd',
        thermalNvme: 'nvme', otherThermals: 'other', speedFan: 'fans',
    };
    if (payload.disabled === true) {
        return 'disabled';
    }
    if (sensors[itemId]) {
        const enabled = payload[sensors[itemId]];
        if (enabled === false) {
            return 'disabled';
        }
        return enabled === true && payload.enhanced_sensors
            && typeof payload.enhanced_sensors === 'object' ? 'ready' : 'pending';
    }
    if (itemId === 'gpu_details' || itemId === 'gpuFans') {
        if (payload.enable_gpu === false || (itemId === 'gpuFans' && payload.enable_fans === false)) {
            return 'disabled';
        }
        return payload.enable_gpu === true && payload.Graphics
            && typeof payload.Graphics === 'object'
            && (itemId !== 'gpuFans' || payload.enable_fans === true) ? 'ready' : 'pending';
    }
    if (itemId === 'storageHealth') {
        return payload.status ? 'ready' : 'pending';
    }
    return Object.values(payload).some(value => value && typeof value === 'object'
        && !Array.isArray(value)) ? 'ready' : 'pending';
}

function getSensorIgnoreThreshold(sensorInfo, tempHelper) {
    const threshold = Number(sensorInfo.ignore_temp_below);
    return tempHelper.getTemp(Number.isFinite(threshold) ? threshold : 5);
}

function getCpuThermalGroups(info) {
    const payload = getSensorPayload(info);
    const helper = Ext.create('PVE.mod.TempHelper', {
        srcUnit: PVE.mod.TempHelper.CELSIUS,
        dstUnit: info.temp_unit === 'F' ? PVE.mod.TempHelper.FAHRENHEIT : PVE.mod.TempHelper.CELSIUS,
    });
    const minimum = getSensorIgnoreThreshold(info, helper);
    return Object.keys(payload)
        .filter(key => /^(coretemp-isa-|k10temp-pci-|cpu_thermal-virtual-)/.test(key))
        .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
        .flatMap(key => {
            const chip = payload[key];
            if (!chip || typeof chip !== 'object') {
                return [];
            }
            const rows = Object.entries(chip).flatMap(([name, feature]) => {
                if (!feature || typeof feature !== 'object') {
                    return [];
                }
                const label = getSensorLabel(feature, name);
                const isCore = /^(?:(?:P|E)\s+Core|Core)\s*\d+$/i.test(label);
                const isCcd = /^Tccd\d+$/i.test(label);
                const isPackage = /^Package id\s*\d+$/i.test(label)
                    || /^(Tdie|Tctl|CPU Core Temp)$/i.test(label);
                if (!isCore && !isCcd && !isPackage && !/^temp\d+$/.test(name)) {
                    return [];
                }
                const raw = getSensorValue(feature, 'input');
                const value = helper.getTemp(raw);
                if (!Number.isFinite(raw) || value < minimum) {
                    return [];
                }
                const max = helper.getTemp(getSensorValue(feature, 'max'));
                const critical = helper.getTemp(getSensorValue(feature, 'crit'));
                const state = Number.isFinite(critical) && value >= critical ? 'critical'
                    : Number.isFinite(max) && value >= max ? 'warning' : 'ok';
                return [{ id: name, label, value, max, critical, state, kind: isCore ? 'core' : isCcd ? 'ccd' : isPackage ? 'package' : 'temperature' }];
            }).sort((a, b) => a.label.localeCompare(b.label, undefined, { numeric: true }));
            if (!rows.length) {
                return [];
            }
            const cores = rows.filter(row => row.kind === 'core' || row.kind === 'ccd');
            const packages = rows.filter(row => row.kind === 'package');
            const preferred = packages.find(row => row.label === 'Tdie')
                || packages.find(row => row.label === 'CPU Core Temp')
                || packages.find(row => row.label === 'Tctl');
            const packageRows = preferred ? [preferred] : packages;
            const selected = info.cpu_temp_target === 'Core' && cores.length ? cores
                : packageRows.length ? packageRows : cores.length ? cores : rows;
            const packageId = packages.find(row => /^Package id/.test(row.label))?.label.match(/\d+/)?.[0];
            return [{
                id: key,
                label: packageId === undefined ? key : `${gettext('Package')} ${packageId}`,
                model: typeof chip.cpu_model === 'string' ? chip.cpu_model : '',
                rows, selected,
            }];
        });
}

function renderCpuThermal(info) {
    this.cpuThermalGroups = isSensorEnabled(info, 'cpu') ? getCpuThermalGroups(info) : [];
    this.cpuThermalUnit = info && info.temp_unit === 'F' ? 'F' : 'C';
    const groups = this.cpuThermalGroups;
    if (!groups.length) {
        return 'N/A';
    }
    const format = value => `${Ext.util.Format.number(value, '0.0')}&deg;${this.cpuThermalUnit}`;
    const colored = (value, state) => {
        const style = state === 'critical' ? 'color: red; font-weight: bold;'
            : state === 'warning' ? 'color: #FFC300; font-weight: bold;' : '';
        return `<span style="${style}">${format(value)}</span>`;
    };
    const rows = groups.map(group => {
        const values = group.selected.map(row => row.value);
        const minimum = group.selected.reduce((a, b) => a.value <= b.value ? a : b);
        const maximum = group.selected.reduce((a, b) => a.value >= b.value ? a : b);
        const average = values.reduce((sum, value) => sum + value, 0) / values.length;
        const averageState = group.selected.some(row => Number.isFinite(row.critical) && average >= row.critical)
            ? 'critical' : group.selected.some(row => Number.isFinite(row.max) && average >= row.max) ? 'warning' : 'ok';
        const summary = `${gettext('Min')}: ${colored(minimum.value, minimum.state)}`
            + ` &middot; ${gettext('Avg')}: ${colored(average, averageState)}`
            + ` &middot; ${gettext('Max')}: ${colored(maximum.value, maximum.state)}`
            + ` <span style="white-space: nowrap; opacity: 0.7;">(${values.length} ${Ext.htmlEncode(gettext('sensors'))})</span>`;
        const label = Ext.htmlEncode(group.model || gettext('Unknown CPU'));
        return `<tr><td style="width: 50%; padding: 2px 10px 2px 20px; vertical-align: top; overflow-wrap: anywhere;">${label}</td>`
            + `<td style="width: 50%; padding: 2px 0 2px 10px; text-align: right; vertical-align: top; white-space: normal; overflow-wrap: anywhere;">${summary}</td></tr>`;
    }).join('');
    return `<table style="width: 100%; table-layout: fixed; border-collapse: collapse;">${rows}</table>`;
}

function getCpuThermalDetailRows(widget, groupId) {
    return widget.cpuThermalGroups.filter(group => group.id === groupId)
        .flatMap(group => group.rows.map(row => ({
        id: JSON.stringify([group.id, row.id]),
        group: group.label, model: group.model, sensor: row.label, value: row.value, state: row.state,
    })));
}

function refreshCpuThermalDetails(widget) {
    const win = widget.cpuThermalWindow;
    if (!win || win.destroyed) {
        return;
    }
    const tabs = win.down('tabpanel');
    const groups = widget.cpuThermalGroups || [];
    groups.forEach(group => {
        let grid = tabs.items.items.find(tab => tab.deviceId === group.id);
        if (!grid) {
            grid = tabs.add({
                xtype: 'grid',
                deviceId: group.id,
                title: Ext.htmlEncode(`${group.model || gettext('CPU')} (${group.label})`),
                scrollable: true,
                viewConfig: { preserveScrollOnRefresh: true },
                store: { fields: ['id', 'group', 'model', 'sensor', 'value', 'state'] },
                columns: [
                    { text: gettext('Package'), dataIndex: 'group', width: 150, renderer: Ext.htmlEncode },
                    { text: gettext('Sensor'), dataIndex: 'sensor', flex: 1, minWidth: 140, renderer: Ext.htmlEncode },
                    { text: `\u00b0${widget.cpuThermalUnit}`, itemId: 'temperatureColumn', dataIndex: 'value', width: 90,
                        renderer: function(value, metadata, record) {
                            const state = record.get('state');
                            metadata.tdStyle = state === 'critical' ? 'color: red; font-weight: bold;'
                                : state === 'warning' ? 'color: #FFC300; font-weight: bold;' : '';
                            return Ext.util.Format.number(value, '0.0');
                        } },
                ],
            });
        }
        const store = grid.getStore();
        const rows = getCpuThermalDetailRows(widget, group.id);
        const ids = new Set(rows.map(row => row.id));
        store.remove(store.getRange().filter(record => !ids.has(record.getId())));
        rows.forEach(row => {
            const record = store.getById(row.id);
            if (record) {
                record.set(row);
                record.commit();
            } else {
                store.add(row);
            }
        });
        grid.down('#temperatureColumn').setText(`\u00b0${widget.cpuThermalUnit}`);
    });
    tabs.items.items.slice().forEach(tab => {
        if (!groups.some(group => group.id === tab.deviceId)) {
            tabs.remove(tab);
        }
    });
    if (!tabs.getActiveTab() && tabs.items.getCount()) {
        tabs.setActiveTab(0);
    }
}

function showCpuThermalDetails(widget) {
    if (widget.cpuThermalWindow && !widget.cpuThermalWindow.destroyed) {
        widget.cpuThermalWindow.toFront();
        return;
    }
    const size = Ext.getBody().getViewSize();
    widget.cpuThermalWindow = Ext.create('Ext.window.Window', {
        title: gettext('CPU temperature sensors - live'),
        modal: true,
        width: Math.min(900, size.width - 32),
        height: Math.min(560, size.height - 64),
        layout: 'fit',
        items: [{ xtype: 'tabpanel' }],
        buttons: [{ text: gettext('Close'), handler: button => button.up('window').close() }],
        listeners: { destroy: function() { widget.cpuThermalWindow = null; } },
    });
    widget.cpuThermalWindow.show();
    refreshCpuThermalDetails(widget);
}

function getGpuDevices(info) {
    return Object.entries(info?.Graphics || {}).flatMap(([type, devices]) =>
        Object.entries(devices && typeof devices === 'object' ? devices : {})
            .filter(([, device]) => device && typeof device === 'object' && !Array.isArray(device))
            .sort(([a], [b]) => a.localeCompare(b)).map(([key, device]) => ({
            type, key, device, stats: device.stats || {},
            name: device.name || device.stats?.name || key,
        }))).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' })
            || a.type.localeCompare(b.type) || a.key.localeCompare(b.key));
}

function formatGpuTemperature(info, value) {
    const number = getSensorValue({ input: value }, 'input');
    if (!Number.isFinite(number)) {
        return null;
    }
    const helper = Ext.create('PVE.mod.TempHelper', {
        srcUnit: PVE.mod.TempHelper.CELSIUS,
        dstUnit: (info.temp_unit || info.Graphics?.temp_unit) === 'F'
            ? PVE.mod.TempHelper.FAHRENHEIT : PVE.mod.TempHelper.CELSIUS,
    });
    const threshold = getSensorValue({ input: info.ignore_temp_below }, 'input');
    if (Number.isFinite(threshold) && number < threshold) {
        return null;
    }
    const style = number >= 80 ? 'color: red; font-weight: bold;'
        : number >= 70 ? 'color: #FFC300; font-weight: bold;' : '';
    return `<span style="${style}">${Ext.util.Format.number(helper.getTemp(number), '0')}${helper.getUnit()}</span>`;
}

function renderGpuSummary(info) {
    this.gpuInfo = info;
    const encode = value => Ext.htmlEncode(String(value));
    const percent = (label, value) => {
        const number = getSensorValue({ input: value }, 'input');
        const style = number >= 90 ? 'color: #d9534f; font-weight: bold;'
            : number >= 70 ? 'color: #f0ad4e; font-weight: bold;' : '';
        return Number.isFinite(number)
            ? `<span style="${style}">${encode(label)}: ${Ext.util.Format.number(number, '0.##')}%</span>` : null;
    };
    return '<table style="width: 100%; border-collapse: collapse; table-layout: fixed;">'
        + getGpuDevices(info).map(({ type, name, stats }) => {
            const parts = type === 'Intel'
                ? [percent(gettext('Render'), stats.engines?.['Render/3D']?.busy),
                    percent(gettext('Video'), stats.engines?.Video?.busy)]
                : [percent(gettext('GPU'), stats.utilization?.gpu),
                    percent(gettext('VRAM'), stats.memory?.total > 0
                        ? stats.memory.used / stats.memory.total * 100 : undefined)];
            const temperature = formatGpuTemperature(info, stats.temperature?.gpu);
            if (temperature) {
                parts.push(`${encode(gettext('Temp'))}: ${temperature}`);
            }
            const summary = parts.filter(Boolean).join(' | ') || encode(gettext('N/A'));
            return `<tr><td style="width: 50%; padding: 2px 10px 2px 20px; vertical-align: top; overflow-wrap: anywhere;">${encode(name)}</td>`
                + `<td style="width: 50%; padding: 2px 0 2px 10px; text-align: right; vertical-align: top; overflow-wrap: anywhere;">${summary}</td></tr>`;
        }).join('') + '</table>';
}

function getGpuDetailRows(info, device) {
    const rows = [];
    const collect = (object, path = []) => {
        Object.entries(object).sort(([a], [b]) => a.localeCompare(b)).forEach(([field, value]) => {
            if (field === 'unit') {
                return;
            }
            const fields = [...path, field];
            if (value && typeof value === 'object' && !Array.isArray(value)) {
                collect(value, fields);
            } else {
                const isTemperature = fields.join('.') === 'stats.temperature.gpu'
                    || (path[0] === 'stats' && path[1] === 'sensors'
                        && /^temp\d+$/.test(path[2]) && ['value', 'max', 'crit'].includes(field));
                const temperature = isTemperature
                    ? formatGpuTemperature({ ...info, ignore_temp_below: undefined }, value) : null;
                const formatted = value === null || value === undefined ? gettext('N/A')
                    : typeof value === 'number' ? Ext.util.Format.number(value, '0.##') : String(value);
                const group = path[1];
                const unit = object.unit || (group === 'utilization' || group === 'fan' || group === 'engines'
                    || group === 'rc6' ? '%' : group === 'frequency' ? 'MHz'
                    : group === 'power' ? 'W' : '');
                const numeric = getSensorValue({ input: value }, 'input');
                const suffix = Number.isFinite(numeric) && unit ? ` ${Ext.htmlEncode(String(unit))}` : '';
                rows.push({
                    id: JSON.stringify(fields),
                    property: fields.filter(part => part !== 'stats').join(' / '),
                    value: temperature || Ext.htmlEncode(formatted) + suffix,
                });
            }
        });
    };
    collect(device);
    return rows.sort((a, b) => a.property.localeCompare(b.property, undefined, { numeric: true, sensitivity: 'base' }));
}

function refreshGpuDetails(widget) {
    const win = widget.gpuWindow;
    if (!win || win.destroyed) {
        return;
    }
    const tabs = win.down('tabpanel');
    const devices = getGpuDevices(widget.gpuInfo);
    const ids = new Set();
    devices.forEach(({ type, key, name, device }) => {
        const id = JSON.stringify([type, device.history_id || device.card || key]);
        ids.add(id);
        let grid = tabs.items.items.find(tab => tab.gpuId === id);
        const rows = getGpuDetailRows(widget.gpuInfo, device);
        if (!grid) {
            grid = tabs.add({
                xtype: 'grid',
                gpuId: id,
                title: Ext.htmlEncode(`${name} (${device.card || key})`),
                scrollable: true,
                viewConfig: { preserveScrollOnRefresh: true, emptyText: gettext('GPU data unavailable') },
                store: { fields: ['id', 'property', 'value'], data: rows, sorters: ['property'] },
                columns: [
                    { text: gettext('Property'), dataIndex: 'property', flex: 1, minWidth: 180, renderer: Ext.htmlEncode },
                    { text: gettext('Value'), dataIndex: 'value', flex: 1, minWidth: 140,
                        renderer: value => value },
                ],
            });
        } else {
            const store = grid.getStore();
            const rowIds = new Set(rows.map(row => row.id));
            store.remove(store.getRange().filter(record => !rowIds.has(record.getId())));
            rows.forEach(row => {
                const record = store.getById(row.id);
                if (record) {
                    record.set(row);
                    record.commit();
                } else {
                    store.add(row);
                }
            });
        }
    });
    tabs.items.items.slice().forEach(tab => {
        if (!ids.has(tab.gpuId)) {
            tabs.remove(tab);
        }
    });
    if (!devices.length) {
        tabs.add({
            xtype: 'panel',
            title: gettext('GPU details'),
            bodyPadding: 15,
            html: Ext.htmlEncode(gettext('GPU data unavailable')),
        });
    }
    if (!tabs.getActiveTab() && tabs.items.getCount()) {
        tabs.setActiveTab(0);
    }
}

function showGpuDetails(widget) {
    if (widget.gpuWindow && !widget.gpuWindow.destroyed) {
        widget.gpuWindow.toFront();
        return;
    }
    const size = Ext.getBody().getViewSize();
    widget.gpuWindow = Ext.create('Ext.window.Window', {
        title: gettext('GPU details - live'),
        modal: true,
        width: Math.min(760, size.width - 32),
        height: Math.min(600, size.height - 64),
        layout: 'fit',
        items: [{ xtype: 'tabpanel' }],
        buttons: [{ text: gettext('Close'), handler: button => button.up('window').close() }],
        listeners: { destroy: function() { widget.gpuWindow = null; } },
    });
    widget.gpuWindow.show();
    refreshGpuDetails(widget);
}

function getUpsStatus(value) {
    const tokens = String(value || '').toUpperCase().split(/\s+/);
    const states = [
        ['FSD', gettext('Shutdown'), 'critical'],
        ['LB', gettext('Low battery'), 'critical'],
        ['RB', gettext('Replace battery'), 'critical'],
        ['OVER', gettext('Overload'), 'critical'],
        ['ALARM', gettext('Alarm'), 'critical'],
        ['OFF', gettext('Off'), 'critical'],
        ['NOCOMM', gettext('No communication'), 'warning'],
        ['OB', gettext('On battery'), 'warning'],
        ['BYPASS', gettext('Bypass'), 'warning'],
        ['CAL', gettext('Calibrating'), 'warning'],
        ['OL', gettext('Online'), 'ok'],
        ['CHRG', gettext('Charging'), 'ok'],
        ['DISCHRG', gettext('Discharging'), 'warning'],
        ['BOOST', gettext('Boosting'), 'warning'],
        ['TRIM', gettext('Trimming'), 'warning'],
    ].filter(([token]) => tokens.includes(token));
    return {
        text: states.length ? states.map(([, label]) => label).join(', ') : value || gettext('Unknown'),
        state: states.some(([, , state]) => state === 'critical') ? 'critical'
            : states.some(([, , state]) => state === 'warning') ? 'warning' : states.length ? 'ok' : 'warning',
    };
}

function formatUpsRuntime(value) {
    const seconds = getSensorValue({ input: value }, 'input');
    if (!Number.isFinite(seconds) || seconds < 0) {
        return gettext('N/A');
    }
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor(seconds % 3600 / 60);
    return hours ? `${hours}h ${minutes}m` : minutes ? `${minutes}m` : `${Math.floor(seconds)}s`;
}

function renderUpsSummary(info) {
    this.upsInfo = info;
    const encode = value => Ext.htmlEncode(String(value));
    const percent = value => {
        const number = getSensorValue({ input: value }, 'input');
        return Number.isFinite(number) && number >= 0 && number <= 100
            ? `${Math.round(number)}%` : gettext('N/A');
    };
    const rows = Object.entries(info || {}).filter(([, data]) =>
        data && typeof data === 'object' && !Array.isArray(data)).map(([key, data]) => {
        const status = getUpsStatus(data['ups.status']);
        const style = status.state === 'critical' ? 'color: red; font-weight: bold;'
            : status.state === 'warning' ? 'color: #FFC300; font-weight: bold;' : '';
        const summary = `<div style="display: flex; justify-content: space-between; gap: 8px;">`
            + `<span style="text-align: left; ${style}">${encode(status.text)}</span>`
            + `<span>${encode(gettext('Capacity'))}: ${encode(percent(data['battery.charge']))}`
            + ` (${encode(formatUpsRuntime(data['battery.runtime']))} ${encode(gettext('left'))})`
            + ` | <span style="white-space: nowrap;">${encode(gettext('Load'))}: ${encode(percent(data['ups.load']))}</span></span></div>`;
        const charge = getSensorValue({ input: data['battery.charge'] }, 'input');
        const chargeAvailable = Number.isFinite(charge) && charge >= 0 && charge <= 100;
        const capacityLabel = encode(gettext('Battery capacity') + ': ' + percent(data['battery.charge']));
        const lowCharge = getSensorValue({ input: data['battery.charge.low'] }, 'input');
        const capacityClass = String(data['ups.status'] || '').split(/\s+/).includes('LB')
            || (Number.isFinite(lowCharge) && charge <= lowCharge) ? 'critical' : '';
        const bar = chargeAvailable
            ? `<div class="x-progress x-progress-default ${capacityClass}" role="progressbar" aria-label="${encode(gettext('Battery capacity'))}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${charge}" aria-valuetext="${capacityLabel}" title="${capacityLabel}" style="height: 5px; margin-top: 3px;"><div class="x-progress-bar x-progress-bar-default" style="height: 5px; width: ${charge}%;"></div></div>`
            : '';
        const serial = data['ups.serial'] || data['device.serial'];
        const modelLabel = encode(data['ups.model'] || data['device.model'] || key)
            + (serial ? ` (${encode(serial)})` : '');
        return `<tr><td style="width: 50%; padding: 2px 10px 2px 20px; vertical-align: top; overflow-wrap: anywhere;">${modelLabel}</td>`
            + `<td style="width: 50%; padding: 2px 0 2px 10px; text-align: right; vertical-align: top; overflow-wrap: anywhere;">${summary}${bar}</td></tr>`;
    });
    return `<table style="width: 100%; table-layout: fixed; border-collapse: collapse;">${rows.join('')}</table>`;
}

function getUpsDetailsHtml(data, key) {
    const encode = value => Ext.htmlEncode(String(value));
    const sections = [
        [gettext('Device'), [
            [gettext('Connection'), null, key],
            [gettext('Manufacturer'), 'ups.mfr', data?.['device.mfr']],
            [gettext('Model'), 'ups.model', data?.['device.model']],
            [gettext('Serial number'), 'ups.serial', data?.['device.serial']],
            [gettext('Status'), null, data ? getUpsStatus(data['ups.status']).text : undefined],
            [gettext('Alarm'), 'ups.alarm'],
            [gettext('Self-test'), 'ups.test.result'],
            [gettext('Beeper'), 'ups.beeper.status'],
        ]],
        [gettext('Battery'), [
            [gettext('Capacity'), 'battery.charge', undefined, '%'],
            [gettext('Estimated runtime'), null, data ? formatUpsRuntime(data['battery.runtime']) : undefined],
            [gettext('Low capacity threshold'), 'battery.charge.low', undefined, '%'],
            [gettext('Low runtime threshold'), null, data?.['battery.runtime.low'] != null
                ? formatUpsRuntime(data['battery.runtime.low']) : undefined],
            [gettext('Voltage'), 'battery.voltage', undefined, ' V'],
            [gettext('Nominal voltage'), 'battery.voltage.nominal', undefined, ' V'],
            [gettext('Type'), 'battery.type'],
            [gettext('Manufacturing date'), 'battery.mfr.date'],
        ]],
        [gettext('Power'), [
            [gettext('Load'), 'ups.load', undefined, '%'],
            [gettext('Output power'), 'ups.realpower', undefined, ' W'],
            [gettext('Rated power'), 'ups.realpower.nominal', undefined, ' W'],
            [gettext('Input voltage'), 'input.voltage', undefined, ' V'],
            [gettext('Nominal input voltage'), 'input.voltage.nominal', undefined, ' V'],
            [gettext('Output voltage'), 'output.voltage', undefined, ' V'],
            [gettext('Input frequency'), 'input.frequency', undefined, ' Hz'],
        ]],
    ];
    const html = sections.map(([title, fields]) => {
        const entries = fields.map(([label, field, fallback, unit = '']) => {
            const value = data?.[field] ?? fallback;
            return value === undefined || value === null ? ''
                : `<tr><td style="width: 50%; padding: 4px 12px 4px 0; vertical-align: top;">${encode(label)}</td>`
                    + `<td style="padding: 4px 0; overflow-wrap: anywhere;">${encode(value)}${unit}</td></tr>`;
        }).join('');
        return entries ? `<h3>${encode(title)}</h3><table style="width: 100%; table-layout: fixed; border-collapse: collapse;">${entries}</table>` : '';
    }).join('');
    return data ? html : encode(gettext('UPS data unavailable'));
}

function refreshUpsDetails(widget) {
    const win = widget.upsWindow;
    if (!win || win.destroyed) {
        return;
    }
    const tabs = win.down('tabpanel');
    const devices = Object.entries(widget.upsInfo || {}).filter(([, data]) =>
        data && typeof data === 'object' && !Array.isArray(data));
    devices.forEach(([key, data]) => {
        let panel = tabs.items.items.find(tab => tab.deviceId === key);
        if (!panel) {
            panel = tabs.add({
                xtype: 'panel',
                deviceId: key,
                title: Ext.htmlEncode(`${data['ups.model'] || data['device.model'] || gettext('UPS')} (${key})`),
                bodyPadding: 15,
                scrollable: true,
            });
        }
        const html = getUpsDetailsHtml(data, key);
        if (panel.detailsHtml !== html) {
            const scrollable = panel.getScrollable();
            const position = scrollable.getPosition();
            panel.update(html);
            panel.detailsHtml = html;
            scrollable.scrollTo(position.x, position.y);
        }
    });
    tabs.items.items.slice().forEach(tab => {
        if (!devices.some(([key]) => key === tab.deviceId)) {
            tabs.remove(tab);
        }
    });
    if (!tabs.getActiveTab() && tabs.items.getCount()) {
        tabs.setActiveTab(0);
    }
}

function showUpsDetails(widget) {
    if (widget.upsWindow && !widget.upsWindow.destroyed) {
        widget.upsWindow.toFront();
        return;
    }
    const size = Ext.getBody().getViewSize();
    widget.upsWindow = Ext.create('Ext.window.Window', {
        title: gettext('UPS details - live'),
        modal: true,
        width: Math.min(760, size.width - 32),
        height: Math.min(560, size.height - 64),
        layout: 'fit',
        items: [{ xtype: 'tabpanel' }],
        buttons: [{ text: gettext('Close'), handler: button => button.up('window').close() }],
        listeners: { destroy: function() { widget.upsWindow = null; } },
    });
    widget.upsWindow.show();
    refreshUpsDetails(widget);
}

function showStorageHealthDetails(widget) {
    const health = widget.storageHealthSnapshot;
    if (!health || !health.status || health.disabled === true) {
        return;
    }
    if (widget.storageHealthWindow && !widget.storageHealthWindow.destroyed) {
        widget.storageHealthWindow.toFront();
        return;
    }

    const encode = value => Ext.htmlEncode(String(value));
    const row = (label, value) => `<div style="margin-bottom: 8px;"><strong>${encode(label)}:</strong> ${encode(value)}</div>`;
    let html = row(gettext('Status'), health.summary || health.status);
    if (Number.isFinite(health.updated)) {
        html += row(gettext('Last updated'), new Date(health.updated * 1000).toLocaleString());
    }
    html += row(gettext('ZFS pools'), health.zfs && health.zfs.available === true
        ? health.zfs.pools : gettext('Unavailable'));
    if (health.smart && health.smart.enabled === false) {
        html += row(gettext('SMART'), gettext('Disabled'));
    } else if (health.smart && health.smart.available === true) {
        html += row(gettext('Drives checked by SMART'), health.smart.devices);
        html += row(gettext('Sleeping (last result shown)'), health.smart.sleeping || 0);
        html += row(gettext('Not checked yet'), health.smart.unchecked || 0);
        if (Number.isFinite(health.smart.updated)) {
            html += row(gettext('SMART last updated'), new Date(health.smart.updated * 1000).toLocaleString());
        }
    } else {
        html += row(gettext('SMART'), gettext('Unavailable'));
    }
    const issues = Array.isArray(health.issues) ? health.issues : [];
    html += `<h3>${encode(gettext('Issues'))}</h3>`;
    html += issues.length
        ? `<ul>${issues.map(issue => `<li>${encode(issue.severity || health.status)}: ${encode(issue.text)}</li>`).join('')}</ul>`
        : `<p>${encode(gettext('No issues detected'))}</p>`;

    const size = Ext.getBody().getViewSize();
    widget.storageHealthWindow = Ext.create('Ext.window.Window', {
        title: gettext('Volumes and drives - snapshot'),
        modal: true,
        width: Math.min(600, size.width - 32),
        height: Math.min(480, size.height - 64),
        layout: 'fit',
        items: [{
            xtype: 'panel',
            bodyPadding: 15,
            scrollable: true,
            html: html,
        }],
        buttons: [{
            text: gettext('Close'),
            handler: function(button) {
                button.up('window').close();
            },
        }],
        listeners: {
            destroy: function() {
                widget.storageHealthWindow = null;
            },
        },
    });
    widget.storageHealthWindow.show();
}

Ext.define('PVE.node.StatusView', {
    extend: 'Proxmox.panel.StatusView',
    alias: 'widget.pveNodeStatus',

    minHeight: 360,
	flex: 1,
	collapsible: true,
	titleCollapse: true,
    bodyPadding: '20 15 20 15',

    layout: {
        type: 'table',
        columns: 2,
	tableAttrs: {
            style: {
                width: '100%',
            },
        },
    },

    defaults: {
        xtype: 'pmxInfoWidget',
        padding: '0 10 2 10',
    },

    items: [
        // ========== Primary Metrics ==========
        {
            xtype: 'box',
            colspan: 2,
            padding: '0',
            html: '<div style="font-size: 16px; font-weight: bold; margin: 5px 0 3px 0; padding: 3px 0; border-bottom: 2px solid #ddd;">Primary Metrics</div>',
        },
        {
            itemId: 'cpu',
            iconCls: 'fa fa-fw pmx-itype-icon-processor pmx-icon',
            title: gettext('CPU Usage'),
            valueField: 'cpu',
            maxField: 'cpuinfo',
            renderer: function(value, record) {
                let result = Proxmox.Utils.render_node_cpu_usage(value, record);
                // Append CPU model if available
                if (record && record.cpuinfo && record.cpuinfo.model) {
                    result += ` (${record.cpuinfo.model})`;
                }
                return result;
            },
        },
        {
            iconCls: 'fa fa-fw pmx-itype-icon-memory pmx-icon',
            itemId: 'memory',
            title: gettext('Memory Usage'),
            valueField: 'memory',
            maxField: 'memory',
            warningThreshold: 0.9,
            criticalThreshold: 0.975,
            renderer: Proxmox.Utils.render_node_size_usage,
        },
        {
            itemId: 'ksm',
            iconCls: 'fa fa-fw fa-clone',
            printBar: false,
            title: gettext('KSM sharing'),
            textField: 'ksm',
            renderer: function (record) {
                return Proxmox.Utils.render_size(record.shared);
            },
        },
        {
            iconCls: 'fa fa-fw fa-hdd-o',
            itemId: 'rootfs',
            title: gettext('Disk (/) Usage'),
            valueField: 'rootfs',
            maxField: 'rootfs',
            renderer: Proxmox.Utils.render_node_size_usage,
        },
        {
            iconCls: 'fa fa-fw fa-refresh',
            itemId: 'swap',
            title: gettext('SWAP Usage'),
            valueField: 'swap',
            maxField: 'swap',
            warningThreshold: 0.4,
            criticalThreshold: 0.8,
            renderer: Proxmox.Utils.render_node_size_usage,
        },
        {
            itemId: 'storageHealth',
            printBar: false,
            title: gettext('Volumes and drives'),
            iconCls: 'fa fa-fw fa-heartbeat',
            textField: 'PveMods_storageHealth',
            listeners: {
                afterrender: function(widget) {
                    widget.getEl().on('click', function() {
                        showStorageHealthDetails(widget);
                    }, null, { delegate: 'button.pve-mods-storage-details' });
                },
                destroy: function(widget) {
                    if (widget.storageHealthWindow) {
                        widget.storageHealthWindow.destroy();
                    }
                },
            },
            renderer: function(health) {
                this.storageHealthSnapshot = health;
                if (!health || typeof health !== 'object') {
                    return '';
                }
                if (health.disabled === true) {
                    return '';
                }
                if (!health.status) {
                    return gettext('Checking...');
                }

                const styles = {
                    critical: 'color: red; font-weight: bold;',
                    warning: 'color: #FFC300; font-weight: bold;',
                };
                const issues = Array.isArray(health.issues) ? health.issues : [];

                let text = Ext.htmlEncode(health.summary || 'OK');
                if (styles[health.status]) {
                    text = `<span style="${styles[health.status]}">${text}</span>`;
                }
                if (issues.length > 1) {
                    text += ` <span style="opacity: 0.7;">(+${issues.length - 1} ${gettext('more')})</span>`;
                }

                return text;
            },
            value: '',
        },
        
        // ========== Secondary Metrics ==========
        {
            xtype: 'box',
            colspan: 2,
            padding: '15 0 5 0',
            html: '<div style="font-size: 14px; font-weight: bold; margin: 10px 0 5px 0; padding: 5px 0; border-bottom: 1px solid #eee; color: #666;">Secondary Metrics</div>',
        },
        {
            itemId: 'load',
            iconCls: 'fa fa-fw fa-tasks',
            title: gettext('CPU Load Average'),
            printBar: false,
            textField: 'loadavg',
        },
        {
            itemId: 'wait',
            iconCls: 'fa fa-fw fa-clock-o',
            title: gettext('CPU I/O Delay'),
            valueField: 'wait',
        },
        {
            itemId: 'thermalCpu',
            colspan: 2,
            printBar: false,
            title: gettext('CPU Thermal State'),
            iconCls: 'fa fa-fw fa-thermometer-half',
            textField: 'PveMods_SensorInfo',
            renderer: renderCpuThermal,
            listeners: {
                afterrender: function(widget) {
                    widget.getEl().on('click', function(event) {
                        showCpuThermalDetails(widget);
                    }, null, { delegate: 'button.pve-mods-cpu-details' });
                },
                destroy: function(widget) {
                    if (widget.cpuThermalWindow) {
                        widget.cpuThermalWindow.destroy();
                    }
                },
            },
        },
        {
            itemId: 'gpu_details',
            colspan: 2,
            iconCls: 'fa fa-fw fa-desktop',
            title: gettext('GPU Details'),
            printBar: false,
            textField: 'PveMods_graphicsInfo',
            renderer: renderGpuSummary,
            listeners: {
                afterrender: function(widget) {
                    widget.getEl().on('click', () => showGpuDetails(widget), null,
                        { delegate: 'button.pve-mods-gpu-details' });
                },
                destroy: function(widget) {
                    if (widget.gpuWindow) {
                        widget.gpuWindow.destroy();
                    }
                },
            },
        },
        {
			itemId: 'thermalRam',
			colspan: 2,
			printBar: false,
			title: gettext('RAM Temperatures'),
			iconCls: 'fa fa-fw fa-thermometer-half',
			textField: 'PveMods_SensorInfo',
			renderer: function(ramInfo) {
				// sensors configuration: RAM entries are normalized by LmSensors.pm into DIMM<slot> keys
				const sensorName = "temp1";
				// ---
				let objValue;
				try {
                    if (!isSensorEnabled(ramInfo, 'ram')) {
                        return '';
                    }
					objValue = getSensorPayload(ramInfo);
				} catch(e) {
                    return '';
				}
				const tempHelper = Ext.create('PVE.mod.TempHelper', {srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: ramInfo.temp_unit === 'F' ? PVE.mod.TempHelper.FAHRENHEIT : PVE.mod.TempHelper.CELSIUS});
                const ignoreThreshold = getSensorIgnoreThreshold(ramInfo, tempHelper);
                const dimmEntries = Object.entries(objValue)
                    .filter(([key]) => /^DIMM\d+$/.test(key))
                    .sort(([a], [b]) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' }));
				let dimmData = [];
				dimmEntries.forEach(([dimmKey, dimm]) => {
					try {
                        const temperature = getTemperatureFeature(dimm, sensorName);
                        const tempVal = tempHelper.getTemp(getSensorValue(temperature, 'input'));
                        const tempMax = tempHelper.getTemp(getSensorValue(temperature, 'max'));
                        const tempCrit = tempHelper.getTemp(getSensorValue(temperature, 'crit'));
						if (!isNaN(tempVal) && tempVal >= ignoreThreshold) {
							let tempStyle = '';
							if (!isNaN(tempMax) && tempVal >= tempMax) {
								tempStyle = 'color: #FFC300; font-weight: bold;';
							}
							if (!isNaN(tempCrit) && tempVal >= tempCrit) {
								tempStyle = 'color: red; font-weight: bold;';
							}
							const slot = dimm.dimm_slot || dimmKey.replace('DIMM', '');
							dimmData.push(`${slot}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, '0.0')}${tempHelper.getUnit()}</span>`);
						}
					} catch(e) { /*_*/ }
				});

				if (dimmData.length === 0) {
					return 'N/A';
				}

				return dimmData.join('&nbsp;| ');
			}
		},
        {
			itemId: 'thermalHdd',
			colspan: 2,
			printBar: false,
			title: gettext('HDD/SSD Temperatures'),
			iconCls: 'fa fa-fw fa-thermometer-half',
			textField: 'PveMods_SensorInfo',
			renderer: function(hddInfo) {
				// sensors configuration
				const addressPrefix = "drivetemp-scsi-";
				// ---
				let objValue;
				try {
                    if (!isSensorEnabled(hddInfo, 'hdd')) {
						return '';
					}
                    objValue = getSensorPayload(hddInfo);
				} catch(e) {
                    return '';
				}

				const tempHelper = Ext.create('PVE.mod.TempHelper', {srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: hddInfo.temp_unit === 'F' ? PVE.mod.TempHelper.FAHRENHEIT : PVE.mod.TempHelper.CELSIUS});
                const ignoreThreshold = getSensorIgnoreThreshold(hddInfo, tempHelper);
				const drvKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' }));
				let drvData = [];
				drvKeys.forEach((drvKey) => {
					try {
						const drv = objValue[drvKey];
                        const temperature = getTemperatureFeature(drv, 'Drive Temperature');
                        const tempVal = tempHelper.getTemp(getSensorValue(temperature, 'input'));
                        const tempMax = tempHelper.getTemp(getSensorValue(temperature, 'max'));
                        const tempCrit = tempHelper.getTemp(getSensorValue(temperature, 'crit'));
						if (!isNaN(tempVal) && tempVal >= ignoreThreshold) {
							let tempStyle = '';
							if (!isNaN(tempMax) && tempVal >= tempMax) {
								tempStyle = 'color: #FFC300; font-weight: bold;';
							}
							if (!isNaN(tempCrit) && tempVal >= tempCrit) {
								tempStyle = 'color: red; font-weight: bold;';
							}
							drvData.push({
								model: drv['model'] || 'Unknown',
								serial: drv['serial'] || '',
								temp: tempVal,
								tempStyle: tempStyle,
								unit: tempHelper.getUnit()
							});
						}
					} catch(e) { /*_*/ }
				});

				if (drvData.length === 0) {
					return 'N/A';
				}

				let html = '<table style="width: 100%; border-collapse: collapse; table-layout: fixed;">';
				drvData.forEach((data, index) => {
					let deviceName = `${index + 1}. ${data.model}`;
                    if (data.serial != "unknown") deviceName += `&nbsp;(${data.serial})`;
					html += '<tr>';
					html += `<td style="padding: 2px 10px 2px 20px; text-align: left; width: 50%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${deviceName}</td>`;
					html += `<td style="padding: 2px 0 2px 10px; text-align: right; width: 50%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;"><span style="${data.tempStyle}">${Ext.util.Format.number(data.temp, '0.0')}${data.unit}</span></td>`;
					html += '</tr>';
				});
				html += '</table>';
				return html;
			}
		},       
        {
			itemId: 'thermalNvme',
			colspan: 2,
			printBar: false,
			title: gettext('NVMe Temperatures'),
			iconCls: 'fa fa-fw fa-thermometer-half',
			textField: 'PveMods_SensorInfo',
			renderer: function(nvmeInfo) {
				// sensors configuration
				const addressPrefix = "nvme-pci-";
				const sensorName = "Composite";
				// display configuration
				const itemsPerRow = 0;
				// ---
				let objValue;
				try {
                    if (!isSensorEnabled(nvmeInfo, 'nvme')) {
						return '';
					}
                    objValue = getSensorPayload(nvmeInfo);
				} catch(e) {
                    return '';
				}

				const tempHelper = Ext.create('PVE.mod.TempHelper', {srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: nvmeInfo.temp_unit === 'F' ? PVE.mod.TempHelper.FAHRENHEIT : PVE.mod.TempHelper.CELSIUS});
                const ignoreThreshold = getSensorIgnoreThreshold(nvmeInfo, tempHelper);
				const nvmeKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();
				let nvmeData = [];
				nvmeKeys.forEach((nvmeKey, index) => {
					try {
						let tempVal = NaN, tempMax = NaN, tempCrit = NaN, model = '', serial = '';
                        const temperature = getTemperatureFeature(objValue[nvmeKey], sensorName);
                        tempVal = tempHelper.getTemp(getSensorValue(temperature, 'input'));
                        tempMax = tempHelper.getTemp(getSensorValue(temperature, 'max'));
                        tempCrit = tempHelper.getTemp(getSensorValue(temperature, 'crit'));
						model = objValue[nvmeKey]['model'] || 'Unknown';
						serial = objValue[nvmeKey]['serial'] || '';
						
						if (!isNaN(tempVal) && tempVal >= ignoreThreshold) {
							let tempStyle = '';
							if (!isNaN(tempMax) && tempVal >= tempMax) {
								tempStyle = 'color: #FFC300; font-weight: bold;';
							}
							if (!isNaN(tempCrit) && tempVal >= tempCrit) {
								tempStyle = 'color: red; font-weight: bold;';
							}
							nvmeData.push({
								model: model,
								serial: serial,
								temp: tempVal,
								tempStyle: tempStyle,
								unit: tempHelper.getUnit()
							});
						}
					} catch(e) { /*_*/ }
				});
				
                if (nvmeData.length === 0) {
                    return 'N/A';
                }
				
                let html = '<table style="width: 100%; border-collapse: collapse; table-layout: fixed;">';
				nvmeData.forEach((data) => {
					let deviceName = data.model;
					if (data.serial) {
						deviceName += `&nbsp;(${data.serial})`;
					}
					html += '<tr>';
                    html += `<td style="padding: 2px 10px 2px 20px; text-align: left; width: 50%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${deviceName}</td>`;
                    html += `<td style="padding: 2px 0 2px 10px; text-align: right; width: 50%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;"><span style="${data.tempStyle}">${Ext.util.Format.number(data.temp, '0.0')}${data.unit}</span></td>`;
					html += '</tr>';
				});
				html += '</table>';
				return html;
            }
        },
        {
			itemId: 'otherThermals',
			colspan: 2,
			printBar: false,
			title: gettext('Other Temperatures'),
			iconCls: 'fa fa-fw fa-thermometer-half',
			textField: 'PveMods_SensorInfo',
			renderer: function(otherInfo) {
				// Prefixes belonging to other known categories (excluded from this view)
				const excludePrefixes = [
					'nvme-pci-',
					'coretemp-isa-',
					'k10temp-pci-',
					'cpu_thermal-virtual-',
					'drivetemp-',
					'DIMM',
				];
				// ---
				let objValue;
				try {
                    if (!isSensorEnabled(otherInfo, 'other')) {
						return '';
					}
                    objValue = getSensorPayload(otherInfo);
				} catch(e) {
                    return '';
				}

				const tempHelper = Ext.create('PVE.mod.TempHelper', {srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: otherInfo.temp_unit === 'F' ? PVE.mod.TempHelper.FAHRENHEIT : PVE.mod.TempHelper.CELSIUS});
                const ignoreThreshold = getSensorIgnoreThreshold(otherInfo, tempHelper);

				// Keep only keys that do not belong to known categories
				const otherKeys = Object.keys(objValue).filter(key =>
					!excludePrefixes.some(prefix => String(key).startsWith(prefix))
				).sort();

				let rows = [];

				otherKeys.forEach(sensorKey => {
					try {
						const sensorObj = objValue[sensorKey];
						if (!sensorObj || typeof sensorObj !== 'object') { return; }

						// Collect all nested temp* sub-objects
                        const tempKeys = Object.keys(sensorObj).filter(k => /^temp\d+$/.test(k)).sort();
						if (tempKeys.length === 0) { return; }

						let tempParts = [];
						tempKeys.forEach(tempKey => {
							try {
								const tempData = sensorObj[tempKey];
								if (!tempData || typeof tempData !== 'object') { return; }

                                const tempVal = tempHelper.getTemp(getSensorValue(tempData, 'input'));
                                const tempMax = tempHelper.getTemp(getSensorValue(tempData, 'max'));
                                const tempCrit = tempHelper.getTemp(getSensorValue(tempData, 'crit'));

								if (!isNaN(tempVal) && tempVal >= ignoreThreshold) {
									let tempStyle = '';
									if (!isNaN(tempMax) && tempVal >= tempMax) {
										tempStyle = 'color: #FFC300; font-weight: bold;';
									}
									if (!isNaN(tempCrit) && tempVal >= tempCrit) {
										tempStyle = 'color: red; font-weight: bold;';
									}
                                    tempParts.push(`${getSensorLabel(tempData, tempKey)}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, '0.0')}${tempHelper.getUnit()}</span>`);
								}
							} catch(e) { /*_*/ }
						});

						if (tempParts.length > 0) {
							rows.push({ label: sensorKey, temps: tempParts.join('&nbsp;| ') });
						}
					} catch(e) { /*_*/ }
				});

				if (rows.length === 0) {
					return '';
				}

				let html = '<table style="width: 100%; border-collapse: collapse; table-layout: fixed;">';
				rows.forEach(row => {
					html += '<tr>';
					html += `<td style="padding: 2px 10px 2px 20px; text-align: left; width: 50%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${row.label}</td>`;
					html += `<td style="padding: 2px 0 2px 10px; text-align: right; width: 50%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;">${row.temps}</td>`;
					html += '</tr>';
				});
				html += '</table>';
				return html;
            }
        },

        // ========== TERTIARY DIAGNOSTICS (Tier 3) ==========
        {
            xtype: 'box',
            colspan: 2,
            padding: '15 0 5 0',
            html: '<div style="font-size: 13px; font-weight: bold; margin: 10px 0 5px 0; padding: 5px 0; border-bottom: 1px solid #eee; color: #666;">Diagnostics</div>',
        },
        {
            itemId: 'speedFan',
            colspan: 2,
            printBar: false,
            title: gettext('System Fans'),
            iconCls: 'fa fa-fw fa-snowflake-o',
            textField: 'PveMods_SensorInfo',
            renderer: function(fansInfo) {
                // ---
                let objValue;
                try {
                    if (!isSensorEnabled(fansInfo, 'fans')) {
						return '';
					}
                    objValue = getSensorPayload(fansInfo);
                } catch(e) {
                    return '';
                }

                // Recursive function to find fan keys and values
                function findFanKeys(obj, fanKeys) {
                    Object.keys(obj).forEach(key => {
                    const value = obj[key];
                    if (/^fan[0-9]+(?:_input)?$/.test(key)) {
                        if (value && typeof value === 'object') {
                            const measurement = value.input
                                || (Object.prototype.hasOwnProperty.call(value, 'value') ? value : null);
                            if (!measurement) {
                                findFanKeys(value, fanKeys);
                                return;
                            }
                            const numericSpeed = Number(measurement.value);
                            if (Number.isFinite(numericSpeed)
                                && (fansInfo.display_zero_speed_fans === true || numericSpeed !== 0)) {
                                fanKeys.push({
                                    key: key.replace(/_input$/, ''),
                                    label: typeof value.label === 'string' ? value.label.trim() : '',
                                    value: numericSpeed,
                                    unit: measurement.unit || 'RPM',
                                });
                            }
                        } else {
                            const numericSpeed = Number(value);
                            if (Number.isFinite(numericSpeed)
                                && (fansInfo.display_zero_speed_fans === true || numericSpeed !== 0)) {
                                fanKeys.push({ key: key.replace(/_input$/, ''), value: numericSpeed, unit: 'RPM' });
                            }
                        }
                        return;
                    }
                    if (typeof value === 'object' && value !== null) {
                        // If the value is an object, recursively call the function
                        findFanKeys(value, fanKeys);
                    }
                    });
                }

                let speeds = [];
                // Loop through the parent keys
                Object.keys(objValue).forEach(parentKey => {
                    const parentObj = objValue[parentKey];
                    // Array to store fan keys and values
                    const fanKeys = [];
                    // Call the recursive function to find fan keys and values
                    findFanKeys(parentObj, fanKeys);
                    // Sort the fan keys
                    fanKeys.sort((a, b) => {
                        if (a.key < b.key) return -1;
                        if (a.key > b.key) return 1;
                        return 0;
                    });
                    // Process each fan key and value
                    fanKeys.forEach(({ key: fanKey, label: fanLabel, value: fanSpeed, unit }) => {
                    try {
                        // Use the custom sensors label when present, otherwise the capitalized key
                        const fan = fanLabel
                            ? Ext.htmlEncode(fanLabel)
                            : fanKey.charAt(0).toUpperCase() + fanKey.slice(1);
                        speeds.push(`${fan}:&nbsp;${fanSpeed} ${unit}`);
                    } catch(e) {
                        console.error(`Error retrieving fan speed for ${fanKey} in ${parentKey}:`, e); // Debug: Log specific error
                    }
                    });
                });
                return '<div style="text-align: left; margin-left: 20px;">' + (speeds.length > 0 ? speeds.join(' | ') : 'N/A') + '</div>';
            }
        },
        {
            itemId: 'gpuFans',
            colspan: 2,
            printBar: false,
            title: gettext('GPU Fans'),
            iconCls: 'fa fa-fw fa-snowflake-o',
            textField: 'PveMods_graphicsInfo',
            renderer: function(gpuStats) {
                try {
                    if ((gpuStats.enable_gpu !== true || gpuStats.enable_fans !== true)) {
                        return '';
                    }
                } catch (e) {
                    return '';
                }

                let rows = [];

                ['Intel', 'NVIDIA', 'AMD'].forEach(type => {
                    Object.keys(gpuStats.Graphics[type] || {}).sort().forEach(key => {
                        const gpuData = gpuStats.Graphics[type][key];
                        const stats = gpuData?.stats;
                        const fan = stats?.fan;

                        if (!fan || fan.speed === undefined || fan.speed === null) {
                            return;
                        }

                        const gpuName = Ext.htmlEncode(gpuData.name || stats?.name || key);
                        const unit = fan.unit || '%';
                        rows.push(
                            '<tr>' +
                            `<td style="padding: 2px 10px 2px 0; text-align: left; width: 30%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${gpuName}</td>` +
                            `<td style="padding: 2px 0 2px 10px; text-align: right; width: 70%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;">Fan: ${fan.speed}${unit}</td>` +
                            '</tr>',
                        );
                    });
                });
                
                if (rows.length === 0) {
                    return '';
                }

                return '<div style="padding-left: 20px; box-sizing: border-box;"><table style="width: 100%; border-collapse: collapse; table-layout: fixed;">' + rows.join('') + '</table></div>';
            },
        },
        {
            itemId: 'upsc',
            colspan: 2,
            title: gettext('UPS Status'),
            iconCls: 'fa fa-fw fa-battery-three-quarters',
            textField: 'PveMods_upsInfo',
            printBar: false,
            renderer: renderUpsSummary,
            listeners: {
                afterrender: function(widget) {
                    widget.getEl().on('click', function(event) {
                        showUpsDetails(widget);
                    }, null, { delegate: 'button.pve-mods-ups-details' });
                },
                destroy: function(widget) {
                    if (widget.upsWindow) {
                        widget.upsWindow.destroy();
                    }
                },
            },
        },
        {
            xtype: 'box',
            colspan: 2,
            padding: '15 0 5 0',
            html: '<div style="font-size: 13px; font-weight: bold; margin: 10px 0 5px 0; padding: 5px 0; border-bottom: 1px solid #eee; color: #666;">System</div>',
        },
        {
            colspan: 2,
            title: gettext('Kernel Version'),
            printBar: false,
            // TODO: remove with next major and only use newish current-kernel textfield
            multiField: true,
            //textField: 'current-kernel',
            renderer: ({ data }) => {
                if (!data['current-kernel']) {
                    return data.kversion;
                }
                let kernel = data['current-kernel'];
                let buildDate = kernel.version.match(/\((.+)\)\s*$/)?.[1] ?? 'unknown';
                return `${kernel.sysname} ${kernel.release} (${buildDate})`;
            },
            value: '',
        },
        {
            colspan: 2,
            title: gettext('Boot Mode'),
            printBar: false,
            textField: 'boot-info',
            renderer: (boot) => {
                if (boot.mode === 'legacy-bios') {
                    return 'Legacy BIOS';
                } else if (boot.mode === 'efi') {
                    return `EFI${boot.secureboot ? ' (Secure Boot)' : ''}`;
                }
                return Proxmox.Utils.unknownText;
            },
            value: '',
        },
        {
            itemId: 'version',
            colspan: 2,
            printBar: false,
            title: gettext('Manager Version'),
            textField: 'pveversion',
            value: '',
        },
        {
            itemId: 'pve_mods_version',
            colspan: 2,
            printBar: false,
            title: gettext('Sensor Mod Version'),
            textField: 'PveMods_Version',
            value: '',
        },
        {
			itemId: 'sysinfo',
			colspan: 2,
			printBar: false,
			title: gettext('Information'),
			textField: 'PveMods_systemInfo',
            renderer: function(sysInfo) {
                try {
                    if (sysInfo.disabled === true) {
                        this.hide();
                        return '';
                    }
                } catch (e) {
                    return '';
                }

                const titleMap = {
                    manufacturer:  'Manufacturer',
                    product_name:  'Product Name',
                    serial_number: 'Serial Number',
                };

                let parts = [];
                ['manufacturer', 'product_name', 'serial_number'].forEach(function(key) {
                    if (sysInfo[key] !== undefined && sysInfo[key] !== null) {
                        parts.push(titleMap[key] + ': ' + sysInfo[key]);
                    }
                });

                return parts.length > 0 ? parts.join(' | ') : '';
            }
		},        
    ],

    updateField: function(field) {
        if (this.modMetricIds.includes(field.itemId)) {
            const payload = this.getRecordValue(field.textField || field.valueField);
            const state = getModMetricState(field.itemId, payload);
            this.modMetricStates[field.itemId] = state;
            if (state === 'disabled') {
                field.setVisible(false);
                field.modMetricReady = false;
                if (field.itemId === 'upsc' && field.upsWindow) {
                    field.upsWindow.close();
                }
                if (field.itemId === 'gpu_details' && field.gpuWindow) {
                    field.gpuWindow.close();
                }
                if (field.itemId === 'thermalCpu' && field.cpuThermalWindow) {
                    field.cpuThermalWindow.close();
                }
                return;
            }
            if (state === 'pending') {
                field.setVisible(field.modMetricReady === true);
                return;
            }
            field.modMetricReady = true;
            field.setVisible(true);
        }
        this.callParent([field]);
        if (field.itemId === 'thermalCpu') {
            refreshCpuThermalDetails(field);
        }
        if (field.itemId === 'upsc') {
            refreshUpsDetails(field);
        }
        if (field.itemId === 'gpu_details') {
            refreshGpuDetails(field);
        }
    },

    updateValues: function(store, records, success) {
        Ext.suspendLayouts();
        try {
            this.callParent([store, records, success]);
        } finally {
            Ext.resumeLayouts(true);
        }
    },

    updateTitle: function () {
        var me = this;
        var uptime = Proxmox.Utils.render_uptime(me.getRecordValue('uptime'));
        let title = Ext.htmlEncode(me.pveSelNode.data.node + ' (' + gettext('Uptime') + ': ' + uptime + ')');
        if (me.modMetricIds.some(id => !me.modMetricStates[id] || me.modMetricStates[id] === 'pending')) {
            title += ' <span style="font-size: 12px; font-weight: normal;">['
                + Ext.htmlEncode(gettext('Loading sensor data...')) + ']</span>';
        }
        me.setTitle(title);
    },

    initComponent: function () {
        let me = this;
        me.modMetricIds = ['thermalCpu', 'thermalRam', 'thermalHdd', 'thermalNvme',
            'otherThermals', 'speedFan', 'gpu_details', 'gpuFans', 'upsc', 'storageHealth'];
        me.modMetricStates = {};

        let stateProvider = Ext.state.Manager.getProvider();
        let repoLink = stateProvider.encodeHToken({
            view: 'server',
            rid: `node/${me.pveSelNode.data.node}`,
            ltab: 'tasks',
            nodetab: 'aptrepositories',
        });

        me.items.push({
            xtype: 'pmxNodeInfoRepoStatus',
            itemId: 'repositoryStatus',
            product: 'Proxmox VE',
            repoLink: `#${repoLink}`,
        });

        me.callParent();
        me.modMetricIds.forEach(id => me.down('#' + id).setVisible(false));
        ['thermalCpu', 'gpu_details', 'thermalHdd', 'thermalNvme', 'otherThermals', 'upsc'].forEach(function(itemId) {
            me.down('#' + itemId).getComponent('label').tpl = new Ext.XTemplate(
                '<div><tpl if="iconCls"><i class="{iconCls}"></i> </tpl>{title}</div>',
                '<div style="width: 100%; white-space: normal;">{usage}</div>'
            );
        });
        [
            ['gpu_details', 'gpu', gettext('GPU details - live')],
            ['thermalCpu', 'cpu', gettext('CPU temperature sensors - live')],
            ['upsc', 'ups', gettext('UPS details - live')],
            ['storageHealth', 'storage', gettext('Storage health details')],
        ].forEach(([itemId, type, label]) => {
            const encoded = Ext.htmlEncode(label);
            const heading = '<tpl if="iconCls"><i class="{iconCls}"></i> </tpl>{title} '
                + `<button type="button" class="pve-mods-${type}-details" aria-label="${encoded}" title="${encoded}" style="padding: 2px 6px; border: 0; background: transparent; color: inherit; font: inherit; cursor: pointer;"><i class="fa fa-info-circle" aria-hidden="true"></i></button>`;
            me.down('#' + itemId).getComponent('label').tpl = new Ext.XTemplate(
                itemId === 'storageHealth'
                    ? `<div class="left-aligned">${heading}</div><div class="right-aligned">{usage}</div>`
                    : `<div>${heading}</div><div style="width: 100%; white-space: normal;">{usage}</div>`
            );
        });
        me.down('#thermalRam').getComponent('label').tpl = new Ext.XTemplate(
            '<div style="display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); align-items: start;">',
            '<div><tpl if="iconCls"><i class="{iconCls}"></i> </tpl>{title}</div>',
            '<div style="padding-left: 10px; text-align: right; white-space: normal; overflow-wrap: anywhere;">{usage}</div>',
            '</div>'
        );
    },
});

// One row per sample: either read from the GPU RRD files (history mode) or built
// from the live status poll (live mode).
Ext.define('pve-rrd-gpu', {
    extend: 'Ext.data.Model',
    fields: [
        'freq_req', 'freq_act', 'rc6',
        'power_gpu', 'power_pkg',
        'render_busy', 'blitter_busy', 'video_busy', 'videnh_busy',
        'gpu_util', 'mem_util', 'mem_used', 'mem_total',
        'power_draw', 'power_limit', 'temp_gpu', 'fan_speed', 'fan_rpm',
        'gtt_used', 'gtt_total',
        {
            name: 'mem_used_pct',
            calculate: function (data) {
                return data.mem_total > 0 && Ext.isNumber(data.mem_used)
                    ? (data.mem_used * 100) / data.mem_total
                    : null;
            },
        },
        {
            name: 'gtt_used_pct',
            calculate: function (data) {
                return data.gtt_total > 0 && Ext.isNumber(data.gtt_used)
                    ? (data.gtt_used * 100) / data.gtt_total : null;
            },
        },
        { type: 'date', dateFormat: 'timestamp', name: 'time' },
    ],
});

// GPU history read from the node's gpurrddata API.
Ext.define('PVE.data.GpuRRDStore', {
    extend: 'Proxmox.data.RRDStore',
    alias: 'store.pveGpuRRDStore',

    model: 'pve-rrd-gpu',
    card: undefined,

    setRRDUrl: function (timeframe, cf) {
        let me = this;
        if (!me.rrdurl) {
            return;
        }
        timeframe = timeframe || me.timeframe;
        cf = cf || me.cf;
        me.proxy.url = `${me.rrdurl}?card=${encodeURIComponent(me.card)}&timeframe=${timeframe}&cf=${cf}`;
    },
});

// Rolling in-browser window of live samples, used when history is not recorded.
Ext.define('PVE.mod.GpuLiveStore', {
    extend: 'Ext.data.Store',

    model: 'pve-rrd-gpu',
    maxSamples: 600,

    startUpdate: Ext.emptyFn,
    stopUpdate: Ext.emptyFn,

    addSample: function (sample) {
        let me = this;
        me.add(Ext.apply({ time: new Date() }, sample));
        let excess = me.getCount() - me.maxSamples;
        if (excess > 0) {
            me.removeAt(0, excess);
        }
    },
});

Ext.define('PVE.mod.GpuGraphs', {
    singleton: true,

    palette: [
        '#115fa6', '#94ae0a', '#a61120', '#ff8809', '#ffd13e',
        '#a61187', '#24ad9a', '#7c7474', '#a66111',
    ],

    // Selectable series per GPU type. 'get' reads the value from the collector's
    // stats object (live mode), 'field' is the RRD data source (history mode).
    // 'on' marks the series that are shown until the user toggles others.
    metricDefs: {
        Intel: [
            { field: 'render_busy', title: gettext('Render/3D'), unit: '%', on: true, get: (s) => s.engines?.['Render/3D']?.busy },
            { field: 'video_busy', title: gettext('Video'), unit: '%', on: true, get: (s) => s.engines?.Video?.busy },
            { field: 'blitter_busy', title: gettext('Blitter'), unit: '%', on: true, get: (s) => s.engines?.Blitter?.busy },
            { field: 'videnh_busy', title: gettext('VideoEnhance'), unit: '%', get: (s) => s.engines?.VideoEnhance?.busy },
            { field: 'rc6', title: gettext('RC6 residency'), unit: '%', get: (s) => s.rc6?.value },
            { field: 'freq_act', title: gettext('Frequency'), unit: 'MHz', get: (s) => s.frequency?.actual },
            { field: 'freq_req', title: gettext('Frequency (requested)'), unit: 'MHz', get: (s) => s.frequency?.requested },
            { field: 'power_gpu', title: gettext('GPU power'), unit: 'W', get: (s) => s.power?.GPU },
            { field: 'power_pkg', title: gettext('Package power'), unit: 'W', get: (s) => s.power?.Package },
        ],
        NVIDIA: [
            { field: 'gpu_util', title: gettext('GPU'), unit: '%', on: true, get: (s) => s.utilization?.gpu },
            { field: 'mem_util', title: gettext('Memory controller'), unit: '%', on: true, get: (s) => s.utilization?.memory },
            {
                field: 'mem_used_pct',
                title: gettext('Memory used'),
                unit: '%',
                on: true,
                get: (s) => (s.memory?.total > 0 ? (s.memory.used * 100) / s.memory.total : undefined),
            },
            { field: 'fan_speed', title: gettext('Fan'), unit: '%', get: (s) => s.fan?.speed },
            { field: 'power_draw', title: gettext('Power draw'), unit: 'W', get: (s) => s.power?.draw },
            { field: 'power_limit', title: gettext('Power limit'), unit: 'W', get: (s) => s.power?.limit },
            { field: 'temp_gpu', title: gettext('Temperature'), unit: '°C', get: (s) => s.temperature?.gpu },
        ],
        AMD: [
            { field: 'gpu_util', title: gettext('GPU'), unit: '%', on: true, get: (s) => s.utilization?.gpu },
            { field: 'mem_util', title: gettext('Memory controller'), unit: '%', get: (s) => s.utilization?.memory },
            { field: 'mem_used_pct', title: gettext('VRAM allocation used'), unit: '%', on: true,
                get: (s) => s.memory?.total > 0 && Ext.isNumber(s.memory.used)
                    ? s.memory.used * 100 / s.memory.total : undefined },
            { field: 'gtt_used_pct', title: gettext('GTT allocation used'), unit: '%',
                get: (s) => s.gtt?.total > 0 && Ext.isNumber(s.gtt.used)
                    ? s.gtt.used * 100 / s.gtt.total : undefined },
            { field: 'freq_act', title: gettext('Frequency'), unit: 'MHz', get: (s) => s.frequency?.actual },
            { field: 'power_draw', title: gettext('Sensor power'), unit: 'W', get: (s) => s.power?.draw },
            { field: 'temp_gpu', title: gettext('Temperature'), unit: '°C', get: (s) => s.temperature?.gpu },
            { field: 'fan_rpm', title: gettext('Fan speed'), unit: 'RPM', get: (s) => s.fan?.speed },
        ],
    },

    // Series offered for a GPU: skips those its collector doesn't report.
    metricsFor: function (type, stats) {
        let me = this;
        let defs = (me.metricDefs[type] || []).filter((m) => Ext.isNumber(m.get(stats || {})));
        return defs.map((m, i) => Ext.apply({ color: me.palette[i % me.palette.length] }, m));
    },

    // One entry per GPU found in the PveMods_graphicsInfo status value.
    devices: function (info) {
        let res = [];
        ['Intel', 'NVIDIA', 'AMD'].forEach((type) => {
            let group = info?.Graphics?.[type] || {};
            Object.keys(group).sort().forEach((key) => {
                let dev = group[key];
                let card = dev.card;
                if (!card && type === 'NVIDIA') {
                    card = `nvidia${dev.index}`;
                } else if (!card) {
                    card = (dev.drm_path || '').split('/').pop();
                }
                if (!card || !/^[a-zA-Z0-9]+$/.test(card) || !dev.stats) {
                    return;
                }
                // history_id (PCI based) names the RRD file; it stays the same when cardN/index change
                let id = /^[a-zA-Z0-9]+$/.test(dev.history_id || '') ? dev.history_id : card;
                res.push({ type, card, id, name: dev.name || dev.stats.name || card, stats: dev.stats });
            });
        });
        return res;
    },

    // Converts collector stats into a row of the pve-rrd-gpu model.
    sample: function (type, stats) {
        let row = {};
        (this.metricDefs[type] || []).forEach((m) => {
            let v = m.get(stats);
            if (Ext.isNumber(v)) {
                row[m.field] = v;
            }
        });
        if (type === 'NVIDIA' || type === 'AMD') {
            row.mem_used = stats.memory?.used;
            row.mem_total = stats.memory?.total;
        }
        if (type === 'AMD') {
            row.gtt_used = stats.gtt?.used;
            row.gtt_total = stats.gtt?.total;
        }
        return row;
    },
});

Ext.define('PVE.mod.SummaryChart', {
    extend: 'Proxmox.widget.RRDChart',
    alias: 'widget.pveModSummaryChart',

    constructor: function (config) {
        let me = this;
        me.callParent([config]);

        let prepareTitle = function () {
            let title = me.header.getTitle();
            title.noWrap = false;
            title.textEl.setStyle({
                'white-space': 'normal',
                'overflow-wrap': 'anywhere',
            });
            title.textEl.dom.title = title.textEl.dom.textContent;
            me.header.updateLayout();
        };
        if (me.rendered) {
            prepareTitle();
        } else {
            me.on('afterrender', prepareTitle, null, { single: true });
        }

        let legend = me.header.items.findBy((item) => item.isDomLegend);
        me.header.remove(legend, false);
        me.controls = me.addDocked({
            xtype: 'toolbar',
            dock: 'top',
            overflowHandler: 'scroller',
            items: [legend],
        })[0];
        if (config.splitAxisLegend) {
            legend.flex = 1;
            const alignLegend = function() {
                const container = legend.el.down('.x-legend-container');
                if (!container) {
                    return;
                }
                legend.el.down('.x-legend-inner').setStyle('width', '100%');
                container.setStyle({ display: 'flex', width: '100%', 'text-align': 'left' });
                let firstRight = true;
                const items = legend.el.query('.x-legend-item');
                const firstStyle = items.length ? getComputedStyle(items[0]) : null;
                items.forEach((item, index) => {
                    const record = legend.getStore().getAt(Number(item.getAttribute('data-recordindex')));
                    const series = me.getSeries().map[record.get('series')];
                    const right = series.getYAxis().getPosition() === 'right';
                    const startsRight = right && firstRight;
                    item.style.marginLeft = startsRight ? 'auto' : '';
                    item.style.borderLeft = startsRight ? firstStyle.borderLeft : '';
                    item.style.borderTopLeftRadius = startsRight ? firstStyle.borderTopLeftRadius : '';
                    item.style.borderBottomLeftRadius = startsRight ? firstStyle.borderBottomLeftRadius : '';
                    if (right) {
                        firstRight = false;
                    }
                    if (startsRight && index > 0) {
                        items[index - 1].style.borderTopRightRadius = firstStyle.borderTopLeftRadius;
                        items[index - 1].style.borderBottomRightRadius = firstStyle.borderBottomLeftRadius;
                    }
                });
            };
            me.mon(legend, 'refresh', alignLegend);
            me.mon(legend, 'itemupdate', alignLegend);
            me.mon(legend, 'afterrender', alignLegend);
        }
    },
});

Ext.define('PVE.mod.GpuChart', {
    extend: 'PVE.mod.SummaryChart',
    alias: 'widget.pveModGpuChart',

    card: undefined,
    metrics: undefined,

    constructor: function (config) {
        let me = this;
        let metrics = config.metrics;
        let sp = Ext.state.Manager.getProvider();
        me.stateKey = `pvemods-gpu-chart-${config.nodename}-${config.card}`;
        let saved = sp?.get(me.stateKey);
        me.shownByUnit = Ext.isObject(saved?.shown) ? saved.shown : {};
        let units = [...new Set(metrics.filter(m => m.unit !== '%').map((m) => m.unit))];
        me.selectedUnit = units.includes(saved?.unit) ? saved.unit : units[0];
        let shownPercent = me.getShownMetrics('%', metrics);

        me.callParent([
            Ext.apply(
                {
                    fields: metrics.map((m) => ({
                        yField: m.field,
                        title: m.title,
                        showInLegend: m.unit === '%',
                        hidden: m.unit === '%' ? !shownPercent.includes(m.field)
                            : m.unit !== me.selectedUnit,
                        tooltip: {
                            trackMouse: true,
                            renderer: function (toolTip, record) {
                                let value = record.get(m.field);
                                if (value === null || value === undefined) {
                                    toolTip.setHtml(gettext('No Data'));
                                } else {
                                    let text = Ext.util.Format.number(value, '0.##');
                                    let time = new Date(record.get('time'));
                                    toolTip.setHtml(`${m.title}: ${text} ${m.unit}<br>${time}`);
                                }
                            },
                        },
                    })),
                    colors: metrics.map((m) => m.color),
                    axes: [
                        {
                            type: 'numeric', position: 'left',
                            fields: metrics.filter(m => m.unit === '%').map(m => m.field),
                            minimum: 0, maximum: 100, grid: true,
                            renderer: 'leftAxisRenderer',
                        },
                        ...(units.length ? [{
                            type: 'numeric', position: 'right',
                            fields: metrics.filter(m => m.unit !== '%').map(m => m.field),
                            minimum: 0, title: me.selectedUnit,
                            renderer: 'leftAxisRenderer',
                        }] : []),
                        { type: 'time', position: 'bottom', fields: ['time'], grid: true },
                    ],
                },
                config,
            ),
        ]);

        me.axes[0].setTitle('%');
        const legend = me.controls.items.first();
        legend.flex = 1;
        const alignLeftLegend = function() {
            const container = legend.el.down('.x-legend-container');
            if (container) {
                container.setStyle('text-align', 'left');
            }
        };
        me.mon(legend, 'refresh', alignLeftLegend);
        me.mon(legend, 'afterrender', alignLeftLegend);
        me.unitLegend = units.length ? me.controls.add(Ext.create('Ext.chart.legend.Legend', {
            padding: 0,
            style: 'cursor: pointer;',
            store: {
                fields: ['unit', 'name', 'mark', 'disabled'],
                data: units.map(unit => ({
                    unit,
                    name: me.unitLabel(unit),
                    mark: metrics.find(metric => metric.unit === unit).color,
                    disabled: unit !== me.selectedUnit,
                })),
            },
            toggleItem: function(index) {
                me.selectUnit(this.getStore().getAt(index).get('unit'));
            },
        })) : null;
        me.mon(me.getLegendStore(), 'update', me.saveLegendState, me);
    },

    unitLabel: function (unit) {
        let names = {
            '%': gettext('Usage'),
            'MHz': gettext('Frequency'),
            'W': gettext('Power'),
            '°C': gettext('Temperature'),
            'RPM': gettext('Fan speed'),
        };
        return names[unit] || unit;
    },

    getShownMetrics: function (unit, metrics) {
        let group = metrics.filter((m) => m.unit === unit);
        let saved = this.shownByUnit[unit];
        let shown = Array.isArray(saved) ? saved.filter((field) => group.some((m) => m.field === field)) : [];
        if (!shown.length) {
            shown = group.filter((m) => m.on).map((m) => m.field);
        }
        return shown.length ? shown : group.map((m) => m.field);
    },

    saveChartState: function () {
        let sp = Ext.state.Manager.getProvider();
        if (sp) {
            sp.set(this.stateKey, { unit: this.selectedUnit, shown: this.shownByUnit });
        }
    },

    saveLegendState: function (store) {
        if (this.switchingUnit) {
            return;
        }
        const shown = store.getRange()
            .filter((record) => !record.get('disabled'))
            .map((record) => this.getSeries().map[record.get('series')].getYField());
        this.shownByUnit['%'] = shown;
        this.saveChartState();
    },

    selectUnit: function (unit) {
        let me = this;
        if (unit === me.selectedUnit) {
            return;
        }
        me.switchingUnit = true;
        me.selectedUnit = unit;
        me.getSeries().forEach((series) => {
            let metric = me.metrics.find((m) => m.field === series.getYField());
            if (metric.unit === '%') {
                return;
            }
            series.setHidden(metric.unit !== unit);
        });
        me.refreshLegendStore();
        me.axes[1].setTitle(unit);
        me.unitLegend.getStore().each(record => record.set('disabled', record.get('unit') !== unit));
        me.redraw();
        me.switchingUnit = false;
        me.saveChartState();
    },
});


Ext.define('PVE.node.Summary', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveNodeSummary',

    scrollable: true,
    bodyPadding: 5,

    showVersions: function () {
        var me = this;

        var nodename = me.pveSelNode.data.node;

        var view = Ext.createWidget('component', {
            autoScroll: true,
            id: 'pkgversions',
            padding: 5,
            style: {
                'white-space': 'pre',
                'font-family': 'monospace',
            },
        });

        var win = Ext.create('Ext.window.Window', {
            title: gettext('Package versions'),
            width: 600,
            height: 600,
            layout: 'fit',
            modal: true,
            items: [view],
            buttons: [
                {
                    xtype: 'button',
                    iconCls: 'fa fa-clipboard',
                    handler: function (button) {
                        window
                            .getSelection()
                            .selectAllChildren(document.getElementById('pkgversions'));
                        document.execCommand('copy');
                    },
                    text: gettext('Copy'),
                },
                {
                    text: gettext('Ok'),
                    handler: function () {
                        this.up('window').close();
                    },
                },
            ],
        });

        Proxmox.Utils.API2Request({
            waitMsgTarget: me,
            url: `/nodes/${nodename}/apt/versions`,
            method: 'GET',
            failure: function (response, opts) {
                win.close();
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function (response, opts) {
                win.show();
                let text = '';
                Ext.Array.each(response.result.data, function (rec) {
                    let version = 'not correctly installed';
                    let pkg = rec.Package;
                    if (rec.OldVersion && rec.CurrentState === 'Installed') {
                        version = rec.OldVersion;
                    }
                    if (rec.RunningKernel) {
                        text += `${pkg}: ${version} (running kernel: ${rec.RunningKernel})\n`;
                    } else if (rec.ManagerVersion) {
                        text += `${pkg}: ${version} (running version: ${rec.ManagerVersion})\n`;
                    } else {
                        text += `${pkg}: ${version}\n`;
                    }
                });

                view.update(Ext.htmlEncode(text));
            },
        });
    },

    updateRepositoryStatus: function () {
        let me = this;
        let repoStatus = me.nodeStatus.down('#repositoryStatus');

        let nodename = me.pveSelNode.data.node;

        Proxmox.Utils.API2Request({
            url: `/nodes/${nodename}/apt/repositories`,
            method: 'GET',
            failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
            success: (response) =>
                repoStatus.setRepositoryInfo(response.result.data['standard-repos']),
        });

        Proxmox.Utils.API2Request({
            url: `/nodes/${nodename}/subscription`,
            method: 'GET',
            failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
            success: function (response, opts) {
                const res = response.result;
                const subscription = res?.data?.status.toLowerCase() === 'active';
                repoStatus.setSubscriptionStatus(subscription);
            },
        });
    },

    initComponent: function () {
        var me = this;

        var nodename = me.pveSelNode.data.node;
        if (!nodename) {
            throw 'no node name specified';
        }

        if (!me.statusStore) {
            throw 'no status storage specified';
        }

        var rstore = me.statusStore;

        var version_btn = new Ext.Button({
            text: gettext('Package versions'),
            handler: function () {
                Proxmox.Utils.checked_command(function () {
                    me.showVersions();
                });
            },
        });

        var rrdstore = Ext.create('Proxmox.data.RRDStore', {
            rrdurl: '/api2/json/nodes/' + nodename + '/rrddata',
            model: 'pve-rrd-node',
        });

        // One chart per GPU, created once the first status poll reports the GPUs.
        let gpuCharts = {};
        let addGpuCharts = function (store, records, success) {
            let container = me.getComponent('itemcontainer');
            let rec = rstore.getById('PveMods_graphicsInfo');
            let info = rec ? rec.data.value : undefined;
            if (!success || !container || !info || info.enable_gpu !== true) {
                return;
            }

            let useHistory = info.gpu_history === true;
            let added = false;
            PVE.mod.GpuGraphs.devices(info).forEach((dev) => {
                let entry = gpuCharts[dev.id];
                if (!entry) {
                    let metrics = PVE.mod.GpuGraphs.metricsFor(dev.type, dev.stats);
                    if (metrics.length === 0) {
                        return;
                    }
                    let store = useHistory
                        ? Ext.create('PVE.data.GpuRRDStore', {
                              rrdurl: '/api2/json/nodes/' + nodename + '/gpurrddata',
                              card: dev.id,
                          })
                        : Ext.create('PVE.mod.GpuLiveStore');
                    let title = `${gettext('GPU')}: ${Ext.htmlEncode(dev.name)} (${dev.card})`;
                    let chart = container.add({
                        xtype: 'pveModGpuChart',
                        itemId: `gpu-${dev.id}`,
                        title: useHistory ? title : `${title} (${gettext('live')})`,
                        card: dev.id,
                        nodename: nodename,
                        columnWidth: 1 / (container.oldFactor || 1),
                        metrics: metrics,
                        store: store,
                    });
                    entry = gpuCharts[dev.id] = { chart: chart, store: store };
                    store.startUpdate();
                    added = true;
                }
                if (!useHistory) {
                    entry.store.addSample(PVE.mod.GpuGraphs.sample(dev.type, dev.stats));
                }
            });

            if (added) {
                Proxmox.Utils.updateColumns(container);
            }
        };

        let nodeStatus = Ext.create('PVE.node.StatusView', {
            xtype: 'pveNodeStatus',
            rstore: rstore,
            width: 770,
            pveSelNode: me.pveSelNode,
        });

        Ext.apply(me, {
            tbar: [version_btn, '->', { xtype: 'proxmoxRRDTypeSelector' }],
            nodeStatus: nodeStatus,
            items: [
                {
                    xtype: 'container',
                    itemId: 'itemcontainer',
                    layout: 'column',
                    minWidth: 700,
                    defaults: {
                        minHeight: 360,
                        padding: 5,
                        columnWidth: 1,
                    },
                    items: [
                        nodeStatus,
                        {
                            xtype: 'pveModSummaryChart',
                            title: gettext('CPU'),
                            splitAxisLegend: true,
                            fields: ['cpu', 'iowait', {
                                yField: 'pressurecpusome',
                                title: gettext('CPU pressure (Some)'),
                                fill: false,
                            }, {
                                yField: 'loadavg',
                                title: gettext('Load average'),
                                fill: false,
                                tooltip: {
                                    trackMouse: true,
                                    renderer: function(tooltip, record) {
                                        const value = record.get('loadavg');
                                        tooltip.setHtml(value === null || value === undefined
                                            ? gettext('No Data')
                                            : `${gettext('Load average')}: ${Ext.util.Format.number(value, '0.##')}<br>${new Date(record.get('time'))}`);
                                    },
                                },
                            }, {
                                yField: 'maxcpu',
                                title: gettext('Logical CPUs'),
                                fill: false,
                                style: { lineWidth: 1.5, lineDash: [6, 4], opacity: 1 },
                                tooltip: {
                                    trackMouse: true,
                                    renderer: function(tooltip, record) {
                                        const value = record.get('maxcpu');
                                        tooltip.setHtml(value === null || value === undefined
                                            ? gettext('No Data')
                                            : `${gettext('Logical CPUs')}: ${Ext.util.Format.number(value, '0')}<br>${new Date(record.get('time'))}`);
                                    },
                                },
                            }],
                            fieldTitles: [gettext('CPU usage'), gettext('IO delay'), gettext('CPU pressure (Some)'),
                                gettext('Load average'), gettext('Logical CPUs')],
                            colors: ['#115fa6', '#94ae0a', '#FFD13E', '#a61187', '#7c7474'],
                            axes: [
                                {
                                    type: 'numeric', position: 'left', fields: ['cpu', 'iowait', 'pressurecpusome'],
                                    minimum: 0, maximum: 100, grid: true, renderer: 'leftAxisRenderer',
                                },
                                {
                                    type: 'numeric', position: 'right', fields: ['loadavg', 'maxcpu'],
                                    minimum: 0, title: gettext('Load average / Logical CPUs'),
                                    renderer: (axis, value) => Ext.util.Format.number(value, '0.##'),
                                },
                                { type: 'time', position: 'bottom', fields: ['time'], grid: true },
                            ],
                            unit: 'percent',
                            store: rrdstore,
                        },
                        {
                            xtype: 'pveModSummaryChart',
                            title: gettext('Memory'),
                            splitAxisLegend: true,
                            fields: [
                                {
                                    yField: 'memtotal',
                                    title: gettext('Total'),
                                    tooltip: {
                                        trackMouse: true,
                                        renderer: function (toolTip, record, item) {
                                            let value = record.get('memtotal');

                                            if (value === null) {
                                                toolTip.setHtml(gettext('No Data'));
                                            } else {
                                                let total = Proxmox.Utils.format_size(value);
                                                let time = new Date(record.get('time'));

                                                let avail = record.get('memavailable');
                                                let availText = '';
                                                if (Ext.isNumeric(avail)) {
                                                    let v = Proxmox.Utils.format_size(avail);
                                                    availText = ` (${gettext('Available')}: ${v})`;
                                                }

                                                toolTip.setHtml(
                                                    `${gettext('Total')}: ${total}${availText}<br>${time}`,
                                                );
                                            }
                                        },
                                    },
                                },
                                {
                                    yField: 'memused',
                                    title: gettext('Used'),
                                    tooltip: {
                                        trackMouse: true,
                                        renderer: function (toolTip, record, item) {
                                            let value = record.get('memused');

                                            if (value === null) {
                                                toolTip.setHtml(gettext('No Data'));
                                            } else {
                                                let total = Proxmox.Utils.format_size(value);
                                                let time = new Date(record.get('time'));

                                                let arc = record.get('arcsize');
                                                let arcText = '';
                                                if (Ext.isNumeric(arc) && arc > 1024 * 1024) {
                                                    let v = Proxmox.Utils.format_size(value - arc);
                                                    arcText = ` (${gettext('Without ZFS ARC')}: ${v})`;
                                                }

                                                toolTip.setHtml(
                                                    `${gettext('Used')}: ${total}${arcText}<br>${time}`,
                                                );
                                            }
                                        },
                                    },
                                },
                                'arcsize',
                                {
                                    type: 'line',
                                    fill: false,
                                    yField: 'memavailable',
                                    title: gettext('Available'),
                                    style: {
                                        lineWidth: 2.5,
                                        opacity: 1,
                                    },
                                },
                                ...[
                                    ['pressurememorysome', gettext('Memory pressure (Some)')],
                                    ['pressurememoryfull', gettext('Memory pressure (Full)')],
                                ].map(([yField, title]) => ({
                                    yField,
                                    title,
                                    fill: false,
                                    tooltip: {
                                        trackMouse: true,
                                        renderer: function(tooltip, record) {
                                            const value = record.get(yField);
                                            tooltip.setHtml(value === null || value === undefined
                                                ? gettext('No Data')
                                                : `${Ext.htmlEncode(title)}: ${Ext.util.Format.number(value, '0.##')}%<br>${new Date(record.get('time'))}`);
                                        },
                                    },
                                })),
                            ],
                            fieldTitles: [
                                gettext('Total'),
                                gettext('Used'),
                                gettext('ZFS ARC'),
                                gettext('Available'),
                                gettext('Memory pressure (Some)'),
                                gettext('Memory pressure (Full)'),
                            ],
                            colors: ['#94ae0a', '#115fa6', '#24AD9A', '#bbde0d', '#FFD13E', '#A61120'],
                            axes: [
                                {
                                    type: 'numeric', position: 'left',
                                    fields: ['memtotal', 'memused', 'arcsize', 'memavailable'],
                                    minimum: 0, grid: true, renderer: 'leftAxisRenderer',
                                },
                                {
                                    type: 'numeric', position: 'right',
                                    fields: ['pressurememorysome', 'pressurememoryfull'],
                                    minimum: 0, maximum: 100, title: gettext('Pressure stall (%)'),
                                    renderer: (axis, value) => Ext.util.Format.number(value, '0.##'),
                                },
                                { type: 'time', position: 'bottom', fields: ['time'], grid: true },
                            ],
                            listeners: {
                                afterrender: function(chart) {
                                    chart.getAxes().find(axis => axis.getPosition() === 'right').setSegmenter('numeric');
                                },
                            },
                            unit: 'bytes',
                            powerOfTwo: true,
                            store: rrdstore,
                        },
                        {
                            xtype: 'pveModSummaryChart',
                            title: gettext('Network Traffic'),
                            fields: ['netin', 'netout'],
                            fieldTitles: [gettext('Incoming'), gettext('Outgoing')],
                            store: rrdstore,
                        },
                        {
                            xtype: 'pveModSummaryChart',
                            title: gettext('IO Pressure Stall'),
                            fieldTitles: ['Some', 'Full'],
                            fields: ['pressureiosome', 'pressureiofull'],
                            colors: ['#FFD13E', '#A61120'],
                            store: rrdstore,
                            unit: 'percent',
                        },
                    ],
                    listeners: {
                        resize: function (panel) {
                            Proxmox.Utils.updateColumns(panel);
                        },
                    },
                },
            ],
            listeners: {
                activate: function () {
                    rstore.setInterval(1000);
                    rstore.startUpdate();
                    rrdstore.startUpdate();
                    Ext.Object.each(gpuCharts, (card, entry) => entry.store.startUpdate());
                },
                destroy: function () {
                    rstore.setInterval(5000);
                    rrdstore.stopUpdate();
                    Ext.Object.each(gpuCharts, (card, entry) => entry.store.stopUpdate());
                },
            },
        });

        me.updateRepositoryStatus();

        me.callParent();

        me.mon(rstore, 'load', addGpuCharts);

        let sp = Ext.state.Manager.getProvider();
        me.mon(sp, 'statechange', function (provider, key, value) {
            if (key !== 'summarycolumns') {
                return;
            }
            Proxmox.Utils.updateColumns(me.getComponent('itemcontainer'));
        });
    },
});
