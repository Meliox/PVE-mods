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
        trAttrs: { valign: 'top' },
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
        // ========== PRIMARY KPIs (Tier 1) ==========
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
            itemId: 'gpu',
            iconCls: 'fa fa-fw fa-desktop',
            title: gettext('GPU Usage'),
            printBar: false,
            textField: 'gpuStats',
            renderer: function(gpuStats) {
                if (!gpuStats || !gpuStats.Graphics) {
                    return '';
                }

                let hasActiveGPU = false;
                let gpuName = '';

                // Check Intel GPUs
                if (gpuStats.Graphics.Intel) {
                    const keys = Object.keys(gpuStats.Graphics.Intel).sort();
                    if (keys.length > 0) {
                        const gpuData = gpuStats.Graphics.Intel[keys[0]];
                        hasActiveGPU = true;
                        gpuName = gpuData.name;
                    }
                }

                // Check NVIDIA GPUs
                if (gpuStats.Graphics.NVIDIA) {
                    const keys = Object.keys(gpuStats.Graphics.NVIDIA).sort();
                    if (keys.length > 0) {
                        const stats = gpuStats.Graphics.NVIDIA[keys[0]].stats;
                        hasActiveGPU = true;
                        gpuName = stats.name;
                    }
                }

                return hasActiveGPU ? gpuName : '';
            },
        },
        {
            itemId: 'gpu_usage',
            iconCls: 'fa fa-fw fa-desktop',
            title: gettext('GPU 0'),
            valueField: 'gpuStats',
            printBar: false,
            textField: 'gpuStats',
            renderer: function(gpuStats) {
                if (!gpuStats || !gpuStats.Graphics) {
                    return '';
                }

                // Check Intel GPUs
                if (gpuStats.Graphics.Intel) {
                    const keys = Object.keys(gpuStats.Graphics.Intel).sort();
                    if (keys.length > 0) {
                        const gpuData = gpuStats.Graphics.Intel[keys[0]];
                        if (gpuData.stats.engines && gpuData.stats.engines['Render/3D']) {
                            const usage = gpuData.stats.engines['Render/3D'].busy;
                            return `${usage}%`;
                        }
                    }
                }

                // Check NVIDIA GPUs
                if (gpuStats.Graphics.NVIDIA) {
                    const keys = Object.keys(gpuStats.Graphics.NVIDIA).sort();
                    if (keys.length > 0) {
                        const stats = gpuStats.Graphics.NVIDIA[keys[0]].stats;
                        if (stats.utilization) {
                            return `${stats.utilization.gpu}%`;
                        }
                    }
                }

                return '';
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
        // Fill the remaining cell so the next colspan:2 section header starts on a new row.
        {
            xtype: 'box',
            html: '',
            padding: 0,
        },
        
        // ========== SECONDARY DETAILS (Tier 2) ==========
        {
            xtype: 'box',
            colspan: 2,
            padding: '15 0 5 0',
            html: '<div style="font-size: 14px; font-weight: bold; margin: 10px 0 5px 0; padding: 5px 0; border-bottom: 1px solid #eee; color: #666;">Secondary Details</div>',
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
            textField: 'sensorsOutput',
            renderer: function(value){
                // sensors configuration
                const cpuTempHelper = Ext.create('PVE.mod.TempHelper', {srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: PVE.mod.TempHelper.CELSIUS});
                // display configuration
                const itemsPerRow = 0;
                // ---
                let objValue;
                try {
                    objValue = JSON.parse(value) || {};
                    objValue = objValue[Object.keys(objValue)[0]] || {};
                } catch(e) {
                    objValue = {};
                }

                const cpuKeysI = Object.keys(objValue).filter(item => String(item).startsWith('coretemp-isa-')).sort();
                const cpuKeysA = Object.keys(objValue).filter(item => String(item).startsWith('k10temp-pci-')).sort();
                const bINTEL = cpuKeysI.length > 0 ? true : false;
                const INTELPackagePrefix = 'Core' == 'Core' ? 'Core ' : 'Package id';
                const INTELPackageCaption = 'Core' == 'Core' ? 'Core' : 'Package';
                let AMDPackagePrefix = 'Tccd';
                let AMDPackageCaption = 'CCD';
                
                if (cpuKeysA.length > 0) {
                    let bTccd = false;
                    let bTctl = false;
                    let bTdie = false;
                    let bCpuCoreTemp = false;
                    cpuKeysA.forEach((cpuKey, cpuIndex) => {
                        let items = objValue[cpuKey];
                        bTccd = Object.keys(items).findIndex(item => { return String(item).startsWith('Tccd'); }) >= 0;
                        bTctl = Object.keys(items).findIndex(item => { return String(item).startsWith('Tctl'); }) >= 0;
                        bTdie = Object.keys(items).findIndex(item => { return String(item).startsWith('Tdie'); }) >= 0;
                        bCpuCoreTemp = Object.keys(items).findIndex(item => { return String(item) === 'CPU Core Temp'; }) >= 0;
                    });
                    if (bTccd && 'Core' == 'Core') {
                        AMDPackagePrefix = 'Tccd';
                        AMDPackageCaption = 'ccd';
                    } else if (bCpuCoreTemp && 'Core' == 'Package') {
                        AMDPackagePrefix = 'CPU Core Temp';
                        AMDPackageCaption = 'CPU Core Temp';
                    } else if (bTdie) {
                        AMDPackagePrefix = 'Tdie';
                        AMDPackageCaption = 'die';
                    } else if (bTctl) {
                        AMDPackagePrefix = 'Tctl';
                        AMDPackageCaption = 'ctl';
                    } else {
                        AMDPackagePrefix = 'temp';
                        AMDPackageCaption = 'Temp';
                    }
                }
                
                const cpuKeys = bINTEL ? cpuKeysI : cpuKeysA;
                const cpuItemPrefix = bINTEL ? INTELPackagePrefix : AMDPackagePrefix;
                const cpuTempCaption = bINTEL ? INTELPackageCaption : AMDPackageCaption;
                const formatTemp = bINTEL ? '0' : '0.0';
                const cpuCount = cpuKeys.length;
                let temps = [];
                
                cpuKeys.forEach((cpuKey, cpuIndex) => {
                    let cpuTemps = [];
                    const items = objValue[cpuKey];
                    const cpuModel = items.cpu_model || '';
                    
                    const itemKeys = Object.keys(items).filter(item => { 
                        if ('Core' == 'Core') {
                            // In Core mode: only show individual cores/CCDs, exclude overall CPU temp
                            return String(item).includes(cpuItemPrefix) || String(item).startsWith('Tccd');
                        } else {
                            // In Package mode: show overall CPU temp and package-level readings
                            return String(item).includes(cpuItemPrefix) || String(item) === 'CPU Core Temp';
                        }
                    }).sort((a, b) => {
                        // Sort cores numerically
                        let numA = parseInt(a.match(/\d+/)?.[0] || '0', 10);
                        let numB = parseInt(b.match(/\d+/)?.[0] || '0', 10);
                        return numA - numB;
                    });
                    
                    itemKeys.forEach((coreKey) => {
                        try {
                            let tempVal = NaN, tempMax = NaN, tempCrit = NaN;
                            Object.keys(items[coreKey]).forEach((secondLevelKey) => {
                                if (secondLevelKey.endsWith('_input')) {
                                    tempVal = cpuTempHelper.getTemp(parseFloat(items[coreKey][secondLevelKey]));
                                } else if (secondLevelKey.endsWith('_max')) {
                                    tempMax = cpuTempHelper.getTemp(parseFloat(items[coreKey][secondLevelKey]));
                                } else if (secondLevelKey.endsWith('_crit')) {
                                    tempCrit = cpuTempHelper.getTemp(parseFloat(items[coreKey][secondLevelKey]));
                                }
                            });
                            
                            if (!isNaN(tempVal)) {
                                let tempStyle = '';
                                if (!isNaN(tempMax) && tempVal >= tempMax) {
                                    tempStyle = 'color: #FFC300; font-weight: bold;';
                                }
                                if (!isNaN(tempCrit) && tempVal >= tempCrit) {
                                    tempStyle = 'color: red; font-weight: bold;';
                                }
                                
                                let tempStr = '';
                                
                                // Enhanced parsing for AMD temperatures
                                if (coreKey.startsWith('Tccd')) {
                                    let tempIndex = coreKey.match(/Tccd(\d+)/);
                                    if (tempIndex !== null && tempIndex.length > 1) {
                                        tempIndex = tempIndex[1];
                                        tempStr = `${cpuTempCaption}&nbsp;${tempIndex}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, formatTemp)}${cpuTempHelper.getUnit()}</span>`;
                                    } else {
                                        tempStr = `${cpuTempCaption}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, formatTemp)}${cpuTempHelper.getUnit()}</span>`;
                                    }
                                }
                                // Handle CPU Core Temp (single overall temperature)
                                else if (coreKey === 'CPU Core Temp') {
                                    tempStr = `${cpuTempCaption}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, formatTemp)}${cpuTempHelper.getUnit()}</span>`;
                                }
                                // Enhanced parsing for Intel cores (P-Core, E-Core, regular Core)
                                else {
                                    let tempIndex = coreKey.match(/(?:P\s+Core|E\s+Core|Core)\s*(\d+)/);
                                    if (tempIndex !== null && tempIndex.length > 1) {
                                        tempIndex = tempIndex[1];
                                        let coreType = coreKey.startsWith('P Core') ? 'P Core' :
                                                    coreKey.startsWith('E Core') ? 'E Core' :
                                                    cpuTempCaption;
                                        tempStr = `${coreType}&nbsp;${tempIndex}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, formatTemp)}${cpuTempHelper.getUnit()}</span>`;
                                    } else {
                                        // fallback for CPUs which do not have a core index
                                        let coreType = coreKey.startsWith('P Core') ? 'P Core' :
                                            coreKey.startsWith('E Core') ? 'E Core' :
                                            cpuTempCaption;
                                        tempStr = `${coreType}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, formatTemp)}${cpuTempHelper.getUnit()}</span>`;
                                    }
                                }
                                
                                cpuTemps.push(tempStr);
                            }
                        } catch (e) { /*_*/ }
                    });
                    
                    if(cpuTemps.length > 0) {
                        temps.push({ model: cpuModel, temps: cpuTemps });
                    }
                });
                
                let html = '<table style="width: 100%; border-collapse: collapse; table-layout: fixed;">';
                temps.forEach((cpuData, cpuIndex) => {
                    const strCoreTemps = cpuData.temps.map((strTemp, index, arr) => { 
                        return strTemp + (index + 1 < arr.length ? (itemsPerRow > 0 && (index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); 
                    });
                    if(strCoreTemps.length > 0) {
                        let cpuLabel = cpuCount > 1 ? `Socket ${cpuIndex + 1}` : 'Socket 1';
                        let cpuModelStr = cpuData.model || 'Unknown CPU';
                        
                        html += '<tr>';
                        html += `<td style="padding: 2px 10px 2px 0; text-align: left; width: 30%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${cpuModelStr}</td>`;
                        html += `<td style="padding: 2px 0 2px 10px; text-align: right; width: 70%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;">${strCoreTemps.join('')}</td>`;
                        html += '</tr>';
                    }
                });
                html += '</table>';
				
                return html.indexOf('<tr>') > 0
                    ? '<div style="padding-left: 20px; box-sizing: border-box;">' + html + '</div>'
                    : 'N/A';
            }
        },
        {
            itemId: 'gpu_details',
            colspan: 2,
            iconCls: 'fa fa-fw fa-desktop',
            title: gettext('GPU Details'),
            printBar: false,
            textField: 'gpuStats',
            renderer: function(gpuStats) {
                if (!gpuStats || !gpuStats.Graphics) {
                    return '';
                }

                let html = '<table style="width: 100%; border-collapse: collapse; table-layout: fixed;">';

                // Intel GPUs - Secondary details
                if (gpuStats.Graphics.Intel) {
                    Object.keys(gpuStats.Graphics.Intel).sort().forEach(key => {
                        const gpuData = gpuStats.Graphics.Intel[key];
                        
                        let details = [];
                        
                        // All engine details
                        if (gpuData.stats.engines) {
                            if (gpuData.stats.engines['Render/3D']) {
                                details.push(`Render/3D: ${gpuData.stats.engines['Render/3D'].busy}%`);
                            }
                            if (gpuData.stats.engines['Video']) {
                                details.push(`Video: ${gpuData.stats.engines['Video'].busy}%`);
                            }
                            if (gpuData.stats.engines['Blitter']) {
                                details.push(`Blitter: ${gpuData.stats.engines['Blitter'].busy}%`);
                            }
                            if (gpuData.stats.engines['VideoEnhance']) {
                                details.push(`VideoEnhance: ${gpuData.stats.engines['VideoEnhance'].busy}%`);
                            }
                        }
                        
                        // Power
                        if (gpuData.stats.power) {
                            details.push(`Power: ${gpuData.stats.power?.GPU ?? 'N/A'} / ${gpuData.stats.power?.Package ?? 'N/A'} ${gpuData.stats.power?.unit || 'W'}`);
                        }
                        
                        // Frequency
                        if (gpuData.stats.frequency) {
                            details.push(`Freq: ${gpuData.stats.frequency?.actual ?? 'N/A'}/${gpuData.stats.frequency?.requested ?? 'N/A'} ${gpuData.stats.frequency?.unit || 'MHz'}`);
                        }
                        
                        html += '<tr>';
                        html += `<td style="padding: 2px 10px 2px 0; text-align: left; width: 30%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${gpuData.name}</td>`;
                        html += `<td style="padding: 2px 0 2px 10px; text-align: right; width: 70%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;">${details.join(' | ')}</td>`;
                        html += '</tr>';
                    });
                }

                // NVIDIA GPUs - Secondary details
                if (gpuStats.Graphics.NVIDIA) {
                    Object.keys(gpuStats.Graphics.NVIDIA).sort().forEach(key => {
                        const gpuData = gpuStats.Graphics.NVIDIA[key];
                        const stats = gpuData.stats;
                        
                        let details = [];
                        
                        // Memory Utilization
                        if (stats.utilization && stats.utilization.memory) {
                            const memUsage = parseInt(stats.utilization.memory);
                            let memStyle = '';
                            if (memUsage >= 90) memStyle = 'color: #d9534f; font-weight: bold;';
                            else if (memUsage >= 70) memStyle = 'color: #f0ad4e; font-weight: bold;';
                            details.push(`<span style="${memStyle}">MEM: ${stats.utilization.memory}%</span>`);
                        }
                        
                        // VRAM Usage
                        if (stats.memory) {
                            const vramUsedGB = parseInt(stats.memory.used);
                            const vramTotalGB = parseInt(stats.memory.total);
                            const vramPercent = (vramUsedGB / vramTotalGB) * 100;
                            let vramStyle = '';
                            if (vramPercent >= 90) vramStyle = 'color: #d9534f; font-weight: bold;';
                            else if (vramPercent >= 70) vramStyle = 'color: #f0ad4e; font-weight: bold;';
                            details.push(`<span style="${vramStyle}">VRAM: ${stats.memory.used}/${stats.memory.total} ${stats.memory.unit}</span>`);
                        }
                        
                        // Temperature
                        if (stats.temperature) {
                            let tempStyle = '';
                            if (stats.temperature.gpu >= 80) {
                                tempStyle = 'color: red; font-weight: bold;';
                            } else if (stats.temperature.gpu >= 70) {
                                tempStyle = 'color: #FFC300; font-weight: bold;';
                            }
                            details.push(`Temp: <span style="${tempStyle}">${stats.temperature.gpu}${stats.temperature.unit}</span>`);
                        }
                        
                        // Power
                        if (stats.power) {
                            details.push(`Power: ${stats.power.draw}/${stats.power.limit} ${stats.power.unit}`);
                        }
                        
                        html += '<tr>';
                        html += `<td style="padding: 2px 10px 2px 0; text-align: left; width: 30%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${stats.name}</td>`;
                        html += `<td style="padding: 2px 0 2px 10px; text-align: right; width: 70%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;">${details.join(' | ')}</td>`;
                        html += '</tr>';
                    });
                }

                html += '</table>';
                return html.indexOf('<tr>') > 0
                    ? '<div style="padding-left: 20px; box-sizing: border-box;">' + html + '</div>'
                    : '';
            },
        },
        {
			itemId: 'thermalNvme',
			colspan: 2,
			printBar: false,
			title: gettext('NVMe Temperatures'),
			iconCls: 'fa fa-fw fa-thermometer-half',
			textField: 'sensorsOutput',
			renderer: function(value) {
				// sensors configuration
				const addressPrefix = "nvme-pci-";
				const sensorName = "Composite";
				const tempHelper = Ext.create('PVE.mod.TempHelper', {srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: PVE.mod.TempHelper.CELSIUS});
				// display configuration
				const itemsPerRow = 0;
				// ---
				let objValue;
				try {
					objValue = JSON.parse(value) || {};
                    objValue = objValue[Object.keys(objValue)[0]] || {};
				} catch(e) {
					objValue = {};
				}
				const nvmeKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();
				let nvmeData = [];
				nvmeKeys.forEach((nvmeKey, index) => {
					try {
						let tempVal = NaN, tempMax = NaN, tempCrit = NaN, model = '', serial = '';
						Object.keys(objValue[nvmeKey][sensorName]).forEach((secondLevelKey) => {
							if (secondLevelKey.endsWith('_input')) {
								tempVal = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));
							} else if (secondLevelKey.endsWith('_max')) {
								tempMax = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));
							} else if (secondLevelKey.endsWith('_crit')) {
								tempCrit = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));
							}
						});
						model = objValue[nvmeKey]['model'] || 'Unknown';
						serial = objValue[nvmeKey]['serial'] || '';
						
						if (!isNaN(tempVal)) {
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
						deviceName += ` (${data.serial})`;
					}
					html += '<tr>';
                    html += `<td style="padding: 2px 10px 2px 0; text-align: left; width: 30%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${deviceName}</td>`;
                    html += `<td style="padding: 2px 0 2px 10px; text-align: right; width: 70%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;"><span style="${data.tempStyle}">${Ext.util.Format.number(data.temp, '0.0')}${data.unit}</span></td>`;
					html += '</tr>';
				});
				html += '</table>';
				return '<div style="padding-left: 20px; box-sizing: border-box;">' + html + '</div>';
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
            textField: 'sensorsOutput',
            renderer: function(value) {
                // ---
                let objValue;
                try {
                    objValue = JSON.parse(value) || {};
                    objValue = objValue[Object.keys(objValue)[0]] || {};
                } catch(e) {
                    objValue = {};
                }

                // Recursive function to find fan keys and values
                function findFanKeys(obj, fanKeys, parentKey = null) {
                    Object.keys(obj).forEach(key => {
                    const value = obj[key];
                    if (typeof value === 'object' && value !== null) {
                        // If the value is an object, recursively call the function
                        findFanKeys(value, fanKeys, key);
                    } else if (/^fan[0-9]+(_input)?$/.test(key)) {
                        if (true != true && value === 0) {
                            // Skip this fan if DISPLAY_ZERO_SPEED_FANS is false and value is 0
                            return;
                        }
                        // If the key matches the pattern, add the parent key and value to the fanKeys array
                        fanKeys.push({ key: parentKey, value: value });
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
                    fanKeys.forEach(({ key: fanKey, value: fanSpeed }) => {
                    try {
                        const fan = fanKey.charAt(0).toUpperCase() + fanKey.slice(1); // Capitalize the first letter of fanKey
                        speeds.push(`${fan}:&nbsp;${fanSpeed} RPM`);
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
            textField: 'gpuStats',
            renderer: function(gpuStats) {
                if (!gpuStats || !gpuStats.Graphics || !gpuStats.Graphics.NVIDIA) {
                    return 'N/A';
                }

                let rows = [];

                Object.keys(gpuStats.Graphics.NVIDIA).sort().forEach(key => {
                    const gpuData = gpuStats.Graphics.NVIDIA[key];
                    const stats = gpuData?.stats;
                    const fan = stats?.fan;

                    if (!fan || fan.speed === undefined || fan.speed === null) {
                        return;
                    }

                    const gpuName = stats?.name || key;
                    const unit = fan.unit || '%';
                    rows.push(
                        '<tr>' +
                        `<td style="padding: 2px 10px 2px 0; text-align: left; width: 30%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">${gpuName}</td>` +
                        `<td style="padding: 2px 0 2px 10px; text-align: right; width: 70%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;">Fan: ${fan.speed}${unit}</td>` +
                        '</tr>',
                    );
                });

                if (rows.length === 0) {
                    return 'N/A';
                }

                return '<div style="padding-left: 20px; box-sizing: border-box;"><table style="width: 100%; border-collapse: collapse; table-layout: fixed;">' + rows.join('') + '</table></div>';
            },
        },
        {
			itemId: 'upsc',
			colspan: 2,
			printBar: false,
			title: gettext('UPS Status'),
			iconCls: 'fa fa-fw fa-battery-three-quarters',
			textField: 'upsStats',
			renderer: function(value) {
                let objValue = {};
                try {
                    // Parse the UPS data
                    if (typeof value === 'string') {
                        objValue = JSON.parse(value) || {};
                    } else if (typeof value === 'object') {
                        objValue = value || {};
                    }
                } catch(e) {
                    objValue = {};
                }
                
                // If objValue is null or empty, return N/A
                if (!objValue || Object.keys(objValue).length === 0) {
                    return 'N/A';
                }

                // Helper function to get status color
                function getStatusColor(status) {
                    if (!status) return '#999';
                    const statusUpper = status.toUpperCase();
                    if (statusUpper.includes('OL')) return null;
                    if (statusUpper.includes('OB')) return '#d9534f';
                    if (statusUpper.includes('LB')) return '#d9534f';
                    return '#f0ad4e';
                }

                // Helper function to get load/charge color
                function getPercentageColor(value, isLoad = false) {
                    if (!value || isNaN(value)) return '#999';
                    const num = parseFloat(value);
                    if (isLoad) {
                        if (num >= 80) return '#d9534f';
                        if (num >= 60) return '#f0ad4e';
                        return null;
                    } else {
                        if (num <= 20) return '#d9534f';
                        if (num <= 50) return '#f0ad4e';
                        return null;
                    }
                }

                // Helper function to format runtime
                function formatRuntime(seconds) {
                    if (!seconds || isNaN(seconds)) return 'N/A';
                    const mins = Math.floor(seconds / 60);
                    const secs = seconds % 60;
                    return `${mins}m ${secs}s`;
                }

                // Process each UPS in the data
                let allDisplayItems = [];
                
                Object.keys(objValue).forEach(upsKey => {
                    const upsData = objValue[upsKey];
                    
                    // Extract key UPS information
                    const batteryCharge = upsData['battery.charge'];
                    const batteryRuntime = upsData['battery.runtime'];
                    const inputVoltage = upsData['input.voltage'];
                    const upsLoad = upsData['ups.load'];
                    const upsStatus = upsData['ups.status'];
                    const upsModel = upsData['ups.model'] || upsData['device.model'];
                    const testResult = upsData['ups.test.result'];
                    const batteryChargeLow = upsData['battery.charge.low'];
                    const batteryRuntimeLow = upsData['battery.runtime.low'];
                    const upsRealPowerNominal = upsData['ups.realpower.nominal'];
                    const batteryMfrDate = upsData['battery.mfr.date'];

                    // Main status line with all metrics
                    let statusLine = '';

                    // Status
                    if (upsStatus) {
                        const statusUpper = upsStatus.toUpperCase();
                        let statusText = 'Unknown';
                        let statusColor = '#f0ad4e';

                        if (statusUpper.includes('OL')) {
                            statusText = 'Online';
                            statusColor = null;
                        } else if (statusUpper.includes('OB')) {
                            statusText = 'On Battery';
                            statusColor = '#d9534f';
                        } else if (statusUpper.includes('LB')) {
                            statusText = 'Low Battery';
                            statusColor = '#d9534f';
                        } else {
                            statusText = upsStatus;
                            statusColor = '#f0ad4e';
                        }

                        let statusStyle = statusColor ? ('color: ' + statusColor + ';') : '';
                        statusLine += 'Status: <span style="' + statusStyle + '">' + statusText + '</span>';
                    } else {
                        statusLine += 'Status: <span>N/A</span>';
                    }

                    // Battery charge
                    if (statusLine) statusLine += ' | ';
                    if (batteryCharge) {
                        const chargeColor = getPercentageColor(batteryCharge, false);
                        let chargeStyle = chargeColor ? ('color: ' + chargeColor + ';') : '';
                        statusLine += 'Battery: <span style="' + chargeStyle + '">' + batteryCharge + '%</span>';
                    } else {
                        statusLine += 'Battery: <span>N/A</span>';
                    }

                    // Load percentage
                    if (statusLine) statusLine += ' | ';
                    if (upsLoad) {
                        const loadColor = getPercentageColor(upsLoad, true);
                        let loadStyle = loadColor ? ('color: ' + loadColor + ';') : '';
                        statusLine += 'Load: <span style="' + loadStyle + '">' + upsLoad + '%</span>';
                    } else {
                        statusLine += 'Load: <span>N/A</span>';
                    }

                    // Runtime
                    if (statusLine) statusLine += ' | ';
                    if (batteryRuntime) {
                        const runtime = parseInt(batteryRuntime);
                        const runtimeLowThreshold = batteryRuntimeLow ? parseInt(batteryRuntimeLow) : 600;
                        let runtimeColor = null;
                        if (runtime <= runtimeLowThreshold / 2) runtimeColor = '#d9534f';
                        else if (runtime <= runtimeLowThreshold) runtimeColor = '#f0ad4e';
                        let runtimeStyle = runtimeColor ? ('color: ' + runtimeColor + ';') : '';
                        statusLine += 'Runtime: <span style="' + runtimeStyle + '">' + formatRuntime(runtime) + '</span>';
                    } else {
                        statusLine += 'Runtime: <span>N/A</span>';
                    }

                    // Input voltage
                    if (statusLine) statusLine += ' | ';
                    if (inputVoltage) {
                        statusLine += 'Input: <span>' + parseFloat(inputVoltage).toFixed(0) + 'V</span>';
                    } else {
                        statusLine += 'Input: <span>N/A</span>';
                    }

                    // Calculate actual watt usage
                    if (statusLine) statusLine += ' | ';
                    let actualWattage = null;
                    if (upsLoad && upsRealPowerNominal) {
                        const load = parseFloat(upsLoad);
                        const nominal = parseFloat(upsRealPowerNominal);
                        if (!isNaN(load) && !isNaN(nominal)) {
                            actualWattage = Math.round((load / 100) * nominal);
                        }
                    }

                    // Real power (calculated watt usage)
                    if (actualWattage !== null) {
                        statusLine += 'Output: <span>' + actualWattage + 'W</span>';
                    } else {
                        statusLine += 'Output: <span>N/A</span>';
                    }

                    // Append battery MFD + last test to the same line (single-line UPS summary)
                    statusLine += ' | Battery MFD: ' + (batteryMfrDate || 'N/A');
                    if (testResult && !testResult.toLowerCase().includes('no test')) {
                        const testColor = testResult.toLowerCase().includes('passed') ? null : '#d9534f';
                        let testStyle = testColor ? ('color: ' + testColor + ';') : '';
                        statusLine += ' | <span style="' + testStyle + '">Test: ' + testResult + '</span>';
                    } else {
                        statusLine += ' | Test: N/A';
                    }
                    
                    // Build UPS display with model on left, details on right
                    let upsHtml = '<tr>';
                    upsHtml += '<td style="padding: 2px 10px 2px 0; text-align: left; width: 30%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word;">' + (upsModel || upsKey) + '</td>';
                    upsHtml += '<td style="padding: 2px 0 2px 10px; text-align: right; width: 70%; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; white-space: normal;">' + statusLine + '</td>';
                    upsHtml += '</tr>';
                    
                    allDisplayItems.push(upsHtml);
                });

                // Format the final output for all UPS devices
                return '<div style="padding-left: 20px; box-sizing: border-box;"><table style="width: 100%; border-collapse: collapse; table-layout: fixed;">' + allDisplayItems.join('') + '</table></div>';
            }
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
            itemId: 'pve_mod_version',
            colspan: 2,
            printBar: false,
            title: gettext('Sensor Mod Version'),
            textField: 'pveModVersion',
            value: '',
        },        
    ],

    updateTitle: function () {
        var me = this;
        var uptime = Proxmox.Utils.render_uptime(me.getRecordValue('uptime'));
        me.setTitle(me.pveSelNode.data.node + ' (' + gettext('Uptime') + ': ' + uptime + ')');
    },

    initComponent: function () {
        let me = this;

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
    },
});
Ext.define('PVE.node.SubscriptionKeyEdit', {
    extend: 'Proxmox.window.Edit',

    title: gettext('Upload Subscription Key'),
    width: 350,

    items: {
        xtype: 'textfield',
        name: 'key',
        value: '',
        fieldLabel: gettext('Subscription Key'),
        labelWidth: 120,
        getSubmitValue: function () {
            return this.processRawValue(this.getRawValue())?.trim();
        },
    },

    initComponent: function () {
        var me = this;

        me.callParent();

        me.load();
    },
});