#!/usr/bin/env bash
#
# This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display sensors information.
#

################### Configuration #############

# Display configuration for HDD, NVME, CPU
# Set to 0 to disable line breaks
# Note: use these settings only if the displayed layout is broken
CPU_ITEMS_PER_ROW=0
NVME_ITEMS_PER_ROW=0
HDD_ITEMS_PER_ROW=0

# Known CPU sensor names. They can be full or partial but should ensure unambiguous identification.
# Should new ones be added, also update logic in configure() function.
KNOWN_CPU_SENSORS=("coretemp-isa-" "k10temp-pci-")

# This script's working directory
SCRIPT_CWD="$(dirname "$(readlink -f "$0")")"

# Files backup location
BACKUP_DIR="$SCRIPT_CWD/backup"

# File paths
PVE_MANAGER_LIB_JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
NODES_PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"

# Debug location
DEBUG_SAVE_PATH="$SCRIPT_CWD"
DEBUG_SAVE_FILENAME="sensorsdata.json"

##################### DO NOT EDIT BELOW #######################
# Only to be used to debug on other systems. Save the "sensor -j" output into a json file.
# Information will be loaded for script configuration and presented in Proxmox.
DEBUG_REMOTE=false
DEBUG_JSON_FILE="/tmp/sensordata.json"

# Helper functions
function msg {
	echo -e "\e[0m$1\e[0m"
}

#echo message in bold
function msgb {
	echo -e "\e[1m$1\e[0m"
}

function info {
	echo -e "\e[0;32m[info] $1\e[0m"
}

function warn {
	echo -e "\e[0;93m[warning] $1\e[0m"
}

function err {
	echo -e "\e[0;31m[error] $1\e[0m"
	exit 1
}

function ask {
	read -p $'\n\e[0;32m'"$1:"$'\e[0m'" " response
	echo $response
}

# End of helper functions

# Function to display usage information
function usage {
	msgb "\nUsage:\n$0 [install | uninstall | save-sensors-data]\n"
	exit 1
}

# Define a function to install packages
function install_packages {
	# Check if the 'sensors' command is available on the system
	if (! command -v sensors &>/dev/null); then
		# If the 'sensors' command is not available, prompt the user to install lm-sensors
		local choiceInstallLmSensors=$(ask "lm-sensors is not installed. Would you like to install it? (y/n)")
		case "$choiceInstallLmSensors" in
			[yY])
				# If the user chooses to install lm-sensors, update the package list and install the package
				apt-get update
				apt-get install lm-sensors
				;;
			[nN])
				# If the user chooses not to install lm-sensors, exit the script with a zero status code
				msg "Decided to not install lm-sensors. The mod cannot run without it. Exiting..."
				exit 0
				;;
			*)
				# If the user enters an invalid input, print an error message and exit the script with a non-zero status code
				err "Invalid input. Exiting..."
				;;
		esac
	fi
}

function configure {
	SENSORS_DETECTED=false
	local sensorsOutput

	if [ $DEBUG_REMOTE = true ]; then
		warn "Remote debugging is used. Sensor readings from dump file $DEBUG_JSON_FILE will be used."
		sensorsOutput=$(cat $DEBUG_JSON_FILE)
	else
		sensorsOutput=$(sensors -j)
	fi

	if [ $? -ne 0 ]; then
		err "Sensor output error.\n\nCommand output:\n${sensorsOutput}\n\nExiting...\n"
	fi

	# Prompt user for which temperature to use
	while true; do
		local choiceTempDisplayType=$(ask "Do you wish to display temperatures for all cores [C] or just an average temperature per CPU [a] (note: AMD only supports average)? (C/a)")
		case "$choiceTempDisplayType" in
			# Set temperature search criteria
			[cC] | "")
				CPU_TEMP_TARGET="Core"
				info "Temperatures will be displayed for all cores."
				;;
			[aA])
				CPU_TEMP_TARGET="Package"
				info "An average temperature will be displayed per CPU."
				;;
			*)
				# If the user enters an invalid input, print an warning message and retry ask.
				warn "Invalid input."
				continue
				;;
		esac
		break
	done

	# Look for ram temps
	msg "\nDetecting support for RAM temperature sensors..."
	if (echo "$sensorsOutput" | grep -q '"SODIMM":'); then
		msg "Detected RAM temperature sensors:\n$(echo "$sensorsOutput" | grep -o '"SODIMM[^"]*"' | sed 's/"//g')"
		ENABLE_RAM_TEMP=true
		SENSORS_DETECTED=true
	else
		warn "No RAM temperature sensors found."
		ENABLE_RAM_TEMP=false
	fi

	# Check if HDD/SSD data is installed
	msg "\nDetecting support for HDD/SDD temperature sensors..."
	if (lsmod | grep -wq "drivetemp"); then
		# Check if SDD/HDD data is available
		if (echo "$sensorsOutput" | grep -q "drivetemp-scsi-"); then
			msg "Detected sensors:\n$(echo "$sensorsOutput" | grep -o '"drivetemp-scsi[^"]*"' | sed 's/"//g')"
			ENABLE_HDD_TEMP=true
			SENSORS_DETECTED=true
		else
			warn "Kernel module \"drivetemp\" is not installed. HDD/SDD temperatures will not be available."
			ENABLE_HDD_TEMP=false
		fi
	else
		warn "No HDD/SSD temperature sensors found."
		ENABLE_HDD_TEMP=false
	fi

	# Check if NVMe data is available
	msg "\nDetecting support for NVMe temperature sensors..."
	if (echo "$sensorsOutput" | grep -q "nvme-"); then
		msg "Detected sensors:\n$(echo "$sensorsOutput" | grep -o '"nvme[^"]*"' | sed 's/"//g')"
		ENABLE_NVME_TEMP=true
		SENSORS_DETECTED=true
	else
		warn "No NVMe temperature sensors found."
		ENABLE_NVME_TEMP=false
	fi

	# Look for fan speeds
	msg "\nDetecting support for fan speed readings..."
	if (echo "$sensorsOutput" | grep -q "fan[0-9]*_input"); then
		msg "Detected fan speed sensors:\n$(echo $sensorsOutput | grep -Po '"[^"]*":\s*\{\s*"fan[0-9]*_input[^}]*' | sed -E 's/"([^"]*)":.*/\1/')"
		ENABLE_FAN_SPEED=true
		SENSORS_DETECTED=true
		# Prompt user for display zero speed fans
		local choiceDisplayZeroSpeedFans=$(ask "Do you wish to display fans reporting a speed of zero? If no, only active fans will be displayed. (Y/n)")
		case "$choiceDisplayZeroSpeedFans" in
			# Set temperature search criteria
			[yY]|"")
				DISPLAY_ZERO_SPEED_FANS=true
				;;
			[nN] )
				DISPLAY_ZERO_SPEED_FANS=false
				;;
			*)
				# If the user enters an invalid input, print an error message and exit the script with a non-zero status code
				err "Invalid input. Exiting..."
				;;
		esac
	else
		warn "No fan speed sensors found."
		ENABLE_FAN_SPEED=false
	fi

	if [ $SENSORS_DETECTED = true ]; then
		local choiceTempUnit=$(ask "Do you wish to display temperatures in degrees Celsius [C] or Fahrenheit [f]? (C/f)")
		case "$choiceTempUnit" in
			[cC] | "")
				TEMP_UNIT="C"
				info "Temperatures will be presented in degrees Celsius."
				;;
			[fF])
				TEMP_UNIT="F"
				info "Temperatures will be presented in degrees Fahrenheit."
				;;
			*)
				warn "Invalid unit selected. Temperatures will be displayed in degrees Celsius."
				TEMP_UNIT="C"
				;;
		esac
	fi

	# DMI Type:
	# 1 ... System Information
	# 2 ... Base Board Information (for self-made PC)
	for i in 1 2; do
		echo "type ${i})"
		dmidecode -t ${i} | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print $1": "$2}'
	done
	local choiceEnableSystemInfo=$(ask "Do you wish to enable system information? (1/2/n)")
	case "$choiceEnableSystemInfo" in
		[1] | "")
			ENABLE_SYSTEM_INFO=true
			SYSTEM_INFO_TYPE=1
			info "System information will be displayed..."
			;;
		[2])
			ENABLE_SYSTEM_INFO=true
			SYSTEM_INFO_TYPE=2
			info "Motherboard information will be displayed..."
			;;
		[nN])
			ENABLE_SYSTEM_INFO=false
			info "System information will NOT be displayed..."
			;;
		*)
			warn "Invalid selection. System information will be displayed."
			ENABLE_SYSTEM_INFO=true
			;;
	esac
	echo # add a new line
}

# Function to install the modification
function install_mod {
	if [[ -n $(cat $NODES_PM_FILE | grep -e "$res->{sensorsOutput}") ]] && [[ -n $(cat $NODES_PM_FILE | grep -e "$res->{systemInfo}") ]]; then
		err "Mod is already installed. Uninstall existing before installing."
		exit
	fi

	msg "\nPreparing mod installation..."

	# Provide sensor configuration
	configure

	# Create backup of original files
	mkdir -p "$BACKUP_DIR"

	local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

	# Perform backup
	# Create backup of original file
	cp "$NODES_PM_FILE" "$BACKUP_DIR/Nodes.pm.$timestamp"
	msg "Backup of \"$NODES_PM_FILE\" saved to \"$BACKUP_DIR/Nodes.pm.$timestamp\"."

	# Create backup of original file
	cp "$PVE_MANAGER_LIB_JS_FILE" "$BACKUP_DIR/pvemanagerlib.js.$timestamp"
	msg "Backup of \"$PVE_MANAGER_LIB_JS_FILE\" saved to \"$BACKUP_DIR/pvemanagerlib.js.$timestamp\"."

	if [ $SENSORS_DETECTED = true ]; then
		local sensorsCmd
		if [ $DEBUG_REMOTE = true ]; then
			sensorsCmd="cat \"$DEBUG_JSON_FILE\""
		else
			# WTF: sensors -f used for Fahrenheit breaks the fan speeds :|
			#local sensorsCmd=$([[ "$TEMP_UNIT" = "F" ]] && echo "sensors -j -f" || echo "sensors -j")
			sensorsCmd="sensors -j"
		fi
		sed -i '/my \$dinfo = df('\''\/'\'', 1);/i\'$'\t''$res->{sensorsOutput} = `'"$sensorsCmd"'`;\n\t# sanitize JSON output\n\t$res->{sensorsOutput} =~ s/ERROR:.+\\s(\\w+):\\s(.+)/\\"$1\\": 0.000,/g;\n\t$res->{sensorsOutput} =~ s/ERROR:.+\\s(\\w+)!/\\"$1\\": 0.000,/g;\n\t$res->{sensorsOutput} =~ s/,(.*[.\\n]*.+})/$1/g;\n' "$NODES_PM_FILE"
		msg "Sensors' output added to \"$NODES_PM_FILE\"."
	fi

	if [ $ENABLE_SYSTEM_INFO = true ]; then
		local systemInfoCmd=$(dmidecode -t ${SYSTEM_INFO_TYPE} | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print $1": "$2}' | awk '{$1=$1};1' | sed 's/$/ |/' | paste -sd " " - | sed 's/ |$//')
		sed -i "/my \$dinfo = df('\/', 1);/i\\\t\$res->{systemInfo} = \"$(echo "$systemInfoCmd")\";\n" "$NODES_PM_FILE"
		msg "System information output added to \"$NODES_PM_FILE\"."
	fi

	# Add new item to the items array in PVE.node.StatusView
	if [[ -z $(cat "$PVE_MANAGER_LIB_JS_FILE" | grep -e "itemId: 'thermal[[:alnum:]]*'") ]]; then
		local tempHelperCtorParams=$([[ "$TEMP_UNIT" = "F" ]] && echo '{srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: PVE.mod.TempHelper.FAHRENHEIT}' || echo '{srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: PVE.mod.TempHelper.CELSIUS}')
		# Expand space in StatusView
		sed -i "/Ext.define('PVE\.node\.StatusView'/,/\},/ {
			s/\(bodyPadding:\) '[^']*'/\1 '20 15 20 15'/
			s/height: [0-9]\+/minHeight: 360,\n\tflex: 1,\n\tcollapsible: true,\n\ttitleCollapse: true/
			s/\(tableAttrs:.*$\)/trAttrs: \{ valign: 'top' \},\n\t\1/
		}" "$PVE_MANAGER_LIB_JS_FILE"
		msg "Expanded space in \"$PVE_MANAGER_LIB_JS_FILE\"."

		sed -i "/^Ext.define('PVE.node.StatusView'/i\
Ext.define('PVE.mod.TempHelper', {\n\
	//singleton: true,\n\
\n\
	requires: ['Ext.util.Format'],\n\
\n\
	statics: {\n\
		CELSIUS: 0,\n\
		FAHRENHEIT: 1\n\
	},\n\
\n\
	srcUnit: null,\n\
	dstUnit: null,\n\
\n\
	isValidUnit: function (unit) {\n\
		return (\n\
			Ext.isNumber(unit) && (unit === this.self.CELSIUS || unit === this.self.FAHRENHEIT)\n\
		);\n\
	},\n\
\n\
	constructor: function (config) {\n\
		this.srcUnit = config && this.isValidUnit(config.srcUnit) ? config.srcUnit : this.self.CELSIUS;\n\
		this.dstUnit = config && this.isValidUnit(config.dstUnit) ? config.dstUnit : this.self.CELSIUS;\n\
	},\n\
\n\
	toFahrenheit: function (tempCelsius) {\n\
		return Ext.isNumber(tempCelsius)\n\
			? tempCelsius * 9 / 5 + 32\n\
			: NaN;\n\
	},\n\
\n\
	toCelsius: function (tempFahrenheit) {\n\
		return Ext.isNumber(tempFahrenheit)\n\
			? (tempFahrenheit - 32) * 5 / 9\n\
			: NaN;\n\
	},\n\
\n\
	getTemp: function (value) {\n\
		if (this.srcUnit !== this.dstUnit) {\n\
			switch (this.srcUnit) {\n\
				case this.self.CELSIUS:\n\
					switch (this.dstUnit) {\n\
						case this.self.FAHRENHEIT:\n\
							return this.toFahrenheit(value);\n\
\n\
						default:\n\
							Ext.raise({\n\
								msg:\n\
									'Unsupported destination temperature unit: ' + this.dstUnit,\n\
							});\n\
					}\n\
				case this.self.FAHRENHEIT:\n\
					switch (this.dstUnit) {\n\
						case this.self.CELSIUS:\n\
							return this.toCelsius(value);\n\
\n\
						default:\n\
							Ext.raise({\n\
								msg:\n\
									'Unsupported destination temperature unit: ' + this.dstUnit,\n\
							});\n\
					}\n\
				default:\n\
					Ext.raise({\n\
						msg: 'Unsupported source temperature unit: ' + this.srcUnit,\n\
					});\n\
			}\n\
		} else {\n\
			return value;\n\
		}\n\
	},\n\
\n\
	getUnit: function(plainText) {\n\
		switch (this.dstUnit) {\n\
			case this.self.CELSIUS:\n\
				return plainText !== true ? '\&deg;C' : '\\\'C';\n\
\n\
			case this.self.FAHRENHEIT:\n\\n\
				return plainText !== true ? '\&deg;F' : '\\\'F';\n\
\n\
			default:\n\
				Ext.raise({\n\
					msg: 'Unsupported destination temperature unit: ' + this.srcUnit,\n\
				});\n\
		}\n\
	},\n\
});\n" "$PVE_MANAGER_LIB_JS_FILE"

		if [ $ENABLE_SYSTEM_INFO = true ]; then
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a;
				/items:/!{N;ba;}
				:b;
				/cpus.*},/!{N;bb;}
				a\
				\\
	{\n\
		itemId: 'sysinfo',\n\
		colspan: 2,\n\
		printBar: false,\n\
		title: gettext('System Information'),\n\
		textField: 'systemInfo',\n\
		renderer: function(value){\n\
			return value;\n\
		}\n\
	},
			}" "$PVE_MANAGER_LIB_JS_FILE"
		fi

		sed -i "/^Ext.define('PVE.node.StatusView',/ {
			:a;
			/items:/!{N;ba;}
			:b;
			/cpus.*},/!{N;bb;}
			a\
			\\
	{\n\
		itemId: 'thermalCpu',\n\
		colspan: 2,\n\
		printBar: false,\n\
		title: gettext('CPU Thermal State'),\n\
		iconCls: 'fa fa-fw fa-thermometer-half',\n\
		textField: 'sensorsOutput',\n\
		renderer: function(value){\n\
			// sensors configuration\n\
			const cpuTempHelper = Ext.create('PVE.mod.TempHelper', $tempHelperCtorParams);\n\
			// display configuration\n\
			const itemsPerRow = $CPU_ITEMS_PER_ROW;\n\
			// ---\n\
			let objValue;\n\
			try {\n\
				objValue = JSON.parse(value) || {};\n\
			} catch(e) {\n\
				objValue = {};\n\
			}\n\
			const cpuKeysI = Object.keys(objValue).filter(item => String(item).startsWith('coretemp-isa-')).sort();\n\
			const cpuKeysA = Object.keys(objValue).filter(item => String(item).startsWith('k10temp-pci-')).sort();\n\
			const bINTEL = cpuKeysI.length > 0 ? true : false;\n\
			const INTELPackagePrefix = '$CPU_TEMP_TARGET' == 'Core' ? 'Core ' : 'Package id';\n\
			const INTELPackageCaption = '$CPU_TEMP_TARGET' == 'Core' ? 'Core' : 'Package';\n\
			let AMDPackagePrefix = 'Tccd';\n\
			let AMDPackageCaption = 'Chiplet';\n\
			if (cpuKeysA.length > 0) {\n\
				let bTccd = false;\n\
				let bTctl = false;\n\
				cpuKeysA.forEach((cpuKey, cpuIndex) => {\n\
					let items = objValue[cpuKey];\n\
					if (Object.keys(items).findIndex(item => { return String(item).startsWith('Tccd'); })) bTccd = true;\n\
					if (Object.keys(items).findIndex(item => { return String(item).startsWith('Tctl'); })) bTctl = true;\n\
				});\n\
				if (bTccd && bTctl && '$CPU_TEMP_TARGET' == 'Core') {\n\
					AMDPackagePrefix = 'Tccd';\n\
					AMDPackageCaption = 'Chiplet';\n\
				} else if (bTctl) {\n\
					AMDPackagePrefix = 'Tctl';\n\
					AMDPackageCaption = 'Temp';\n\
				} else {\n\
					AMDPackagePrefix = 'temp';\n\
					AMDPackageCaption = 'Temp';\n\
				}\n\
			}\n\
			const cpuKeys = bINTEL ? cpuKeysI : cpuKeysA;\n\
			const cpuItemPrefix = bINTEL ? INTELPackagePrefix : AMDPackagePrefix;\n\
			const cpuTempCaption = bINTEL ? INTELPackageCaption : AMDPackageCaption;\n\
			const formatTemp = bINTEL ? '0' : '0.0';\n\
			const cpuCount = cpuKeys.length;\n\
			let temps = [];\n\
			cpuKeys.forEach((cpuKey, cpuIndex) => {\n\
				let cpuTemps = [];\n\
				const items = objValue[cpuKey];\n\
				const itemKeys = Object.keys(items).filter(item => { return String(item).startsWith(cpuItemPrefix); });\n\
				itemKeys.forEach((coreKey) => {\n\
					try {\n\
						let tempVal = NaN, tempMax = NaN, tempCrit = NaN;\n\
						Object.keys(items[coreKey]).forEach((secondLevelKey) => {\n\
							if (secondLevelKey.endsWith('_input')) {\n\
								tempVal = cpuTempHelper.getTemp(parseFloat(items[coreKey][secondLevelKey]));\n\
							} else if (secondLevelKey.endsWith('_max')) {\n\
								tempMax = cpuTempHelper.getTemp(parseFloat(items[coreKey][secondLevelKey]));\n\
							} else if (secondLevelKey.endsWith('_crit')) {\n\
								tempCrit = cpuTempHelper.getTemp(parseFloat(items[coreKey][secondLevelKey]));\n\
							}\n\
						});\n\
						if (!isNaN(tempVal)) {\n\
							let tempStyle = '';\n\
							if (!isNaN(tempMax) && tempVal >= tempMax) {\n\
								tempStyle = 'color: #FFC300; font-weight: bold;';\n\
							}\n\
							if (!isNaN(tempCrit) && tempVal >= tempCrit) {\n\
								tempStyle = 'color: red; font-weight: bold;';\n\
							}\n\
							let tempStr = '';\n\
							let tempIndex = coreKey.match(/\\\S+\\\s*(\\\d+)/);\n\
							if (tempIndex !== null && tempIndex.length > 1) {\n\
								tempIndex = tempIndex[1];\n\
								tempStr = \`\${cpuTempCaption}&nbsp;\${tempIndex}:&nbsp;<span style=\"\${tempStyle}\">\${Ext.util.Format.number(tempVal, formatTemp)}\${cpuTempHelper.getUnit()}</span>\`;\n\
							} else {\n\
								tempStr = \`\${cpuTempCaption}:&nbsp;\${Ext.util.Format.number(tempVal, formatTemp)}\${cpuTempHelper.getUnit()}\`;\n\
							}\n\
							cpuTemps.push(tempStr);\n\
						}\n\
					} catch (e) { /*_*/ }\n\
				});\n\
				if(cpuTemps.length > 0) {\n\
					temps.push(cpuTemps);\n\
				}\n\
			});\n\
			let result = '';\n\
			temps.forEach((cpuTemps, cpuIndex) => {\n\
				const strCoreTemps = cpuTemps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? (itemsPerRow > 0 && (index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); })\n\
				if(strCoreTemps.length > 0) {\n\
					result += (cpuCount > 1 ? \`CPU \${cpuIndex+1}: \` : '') + strCoreTemps.join('') + (cpuIndex < cpuCount ? '<br>' : '');\n\
				}\n\
			});\n\
			return '<div style=\"text-align: left; margin-left: 28px;\">' + (result.length > 0 ? result : 'N/A') + '</div>';\n\
		}\n\
	},
		}" "$PVE_MANAGER_LIB_JS_FILE"

		#
		# NOTE: The following items will be added in reverse order
		#
		if [ $ENABLE_HDD_TEMP = true ]; then
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a;
				/items:/!{N;ba;}
				:b;
				/'thermal.*},/!{N;bb;}
				a\
				\\
	{\n\
		itemId: 'thermalHdd',\n\
		colspan: 2,\n\
		printBar: false,\n\
		title: gettext('HDD/SSD Thermal State'),\n\
		iconCls: 'fa fa-fw fa-thermometer-half',\n\
		textField: 'sensorsOutput',\n\
		renderer: function(value) {\n\
			// sensors configuration\n\
			const addressPrefix = \"drivetemp-scsi-\";\n\
			const sensorName = \"temp1\";\n\
			const tempHelper = Ext.create('PVE.mod.TempHelper', $tempHelperCtorParams);\n\
			// display configuration\n\
			const itemsPerRow = ${HDD_ITEMS_PER_ROW};\n\
			// ---\n\
			let objValue;\n\
			try {\n\
				objValue = JSON.parse(value) || {};\n\
			} catch(e) {\n\
				objValue = {};\n\
			}\n\
			const drvKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();\n\
			let temps = [];\n\
			drvKeys.forEach((drvKey, index) => {\n\
				try {\n\
					let tempVal = NaN, tempMax = NaN, tempCrit = NaN;\n\
					Object.keys(objValue[drvKey][sensorName]).forEach((secondLevelKey) => {\n\
						if (secondLevelKey.endsWith('_input')) {\n\
							tempVal = tempHelper.getTemp(parseFloat(objValue[drvKey][sensorName][secondLevelKey]));\n\
						} else if (secondLevelKey.endsWith('_max')) {\n\
							tempMax = tempHelper.getTemp(parseFloat(objValue[drvKey][sensorName][secondLevelKey]));\n\
						} else if (secondLevelKey.endsWith('_crit')) {\n\
							tempCrit = tempHelper.getTemp(parseFloat(objValue[drvKey][sensorName][secondLevelKey]));\n\
						}\n\
					});\n\
					if (!isNaN(tempVal)) {\n\
						let tempStyle = '';\n\
						if (!isNaN(tempMax) && tempVal >= tempMax) {\n\
							tempStyle = 'color: #FFC300; font-weight: bold;';\n\
						}\n\
						if (!isNaN(tempCrit) && tempVal >= tempCrit) {\n\
							tempStyle = 'color: red; font-weight: bold;';\n\
						}\n\
						const tempStr = \`Drive&nbsp;\${index + 1}:&nbsp;<span style=\"\${tempStyle}\">\${Ext.util.Format.number(tempVal, '0.0')}\${tempHelper.getUnit()}</span>\`;\n\
						temps.push(tempStr);\n\
					}\n\
				} catch(e) { /*_*/ }\n\
			});\n\
			const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); });\n\
			return '<div style=\"text-align: left; margin-left: 28px;\">' + (result.length > 0 ? result.join('') : 'N/A') + '</div>';\n\
		}\n\
	},
		}" "$PVE_MANAGER_LIB_JS_FILE"
		fi

		if [ $ENABLE_NVME_TEMP = true ]; then
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a;
				/items:/!{N;ba;}
				:b;
				/'thermal.*},/!{N;bb;}
				a\
				\\
	{\n\
		itemId: 'thermalNvme',\n\
		colspan: 2,\n\
		printBar: false,\n\
		title: gettext('NVMe Thermal State'),\n\
		iconCls: 'fa fa-fw fa-thermometer-half',\n\
		textField: 'sensorsOutput',\n\
		renderer: function(value) {\n\
			// sensors configuration\n\
			const addressPrefix = \"nvme-pci-\";\n\
			const sensorName = \"Composite\";\n\
			const tempHelper = Ext.create('PVE.mod.TempHelper', $tempHelperCtorParams);\n\
			// display configuration\n\
			const itemsPerRow = ${NVME_ITEMS_PER_ROW};\n\
			// ---\n\
			let objValue;\n\
			try {\n\
				objValue = JSON.parse(value) || {};\n\
			} catch(e) {\n\
				objValue = {};\n\
			}\n\
			const nvmeKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();\n\
			let temps = [];\n\
			nvmeKeys.forEach((nvmeKey, index) => {\n\
				try {\n\
					let tempVal = NaN, tempMax = NaN, tempCrit = NaN;\n\
					Object.keys(objValue[nvmeKey][sensorName]).forEach((secondLevelKey) => {\n\
						if (secondLevelKey.endsWith('_input')) {\n\
							tempVal = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));\n\
						} else if (secondLevelKey.endsWith('_max')) {\n\
							tempMax = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));\n\
						} else if (secondLevelKey.endsWith('_crit')) {\n\
							tempCrit = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));\n\
						}\n\
					});\n\
					if (!isNaN(tempVal)) {\n\
						let tempStyle = '';\n\
						if (!isNaN(tempMax) && tempVal >= tempMax) {\n\
							tempStyle = 'color: #FFC300; font-weight: bold;';\n\
						}\n\
						if (!isNaN(tempCrit) && tempVal >= tempCrit) {\n\
							tempStyle = 'color: red; font-weight: bold;';\n\
						}\n\
						const tempStr = \`Drive&nbsp;\${index + 1}:&nbsp;<span style=\"\${tempStyle}\">\${Ext.util.Format.number(tempVal, '0.0')}\${tempHelper.getUnit()}</span>\`;\n\
						temps.push(tempStr);\n\
					}\n\
				} catch(e) { /*_*/ }\n\
			});\n\
			const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); });\n\
			return '<div style=\"text-align: left; margin-left: 28px;\">' + (result.length > 0 ? result.join('') : 'N/A') + '</div>';\n\
		}\n\
	},
		}" "$PVE_MANAGER_LIB_JS_FILE"
		fi

		if [ $ENABLE_NVME_TEMP = true -o $ENABLE_HDD_TEMP = true ]; then
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a;
				/items:/!{N;ba;}
				:b;
				/'thermal.*},/!{N;bb;}
				a\
				\\
	{\n\
		xtype: 'box',\n\
		colspan: 2,\n\
		html: gettext('Drive(s)'),\n\
	},
		}" "$PVE_MANAGER_LIB_JS_FILE"
		fi

		if [ $ENABLE_FAN_SPEED = true ]; then
			# Add fan speeds display
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a;
				/items:/!{N;ba;}
				:b;
				/'thermal.*},/!{N;bb;}
				a\
				\\
	{\n\
		xtype: 'box',\n\
		colspan: 2,\n\
		html: gettext('Cooling'),\n\
	},\n\
	{\n\
		itemId: 'speedFan',\n\
		colspan: 2,\n\
		printBar: false,\n\
		title: gettext('Fan Speed(s)'),\n\
		iconCls: 'fa fa-fw fa-snowflake-o',\n\
		textField: 'sensorsOutput',\n\
		renderer: function(value) {\n\
			// ---\n\
			let objValue;\n\
			try {\n\
				objValue = JSON.parse(value) || {};\n\
			} catch(e) {\n\
				objValue = {};\n\
			}\n\
\n\
			// Recursive function to find fan keys and values\n\
			function findFanKeys(obj, fanKeys, parentKey = null) {\n\
				Object.keys(obj).forEach(key => {\n\
				const value = obj[key];\n\
				if (typeof value === 'object' && value !== null) {\n\
					// If the value is an object, recursively call the function\n\
					findFanKeys(value, fanKeys, key);\n\
				} else if (/^fan[0-9]+(_input)?$/.test(key)) {\n\
					if ($DISPLAY_ZERO_SPEED_FANS != true && value === 0) {\n\
						// Skip this fan if DISPLAY_ZERO_SPEED_FANS is false and value is 0\n\
						return;\n\
					}\n\
					// If the key matches the pattern, add the parent key and value to the fanKeys array\n\
					fanKeys.push({ key: parentKey, value: value });\n\
				}\n\
				});\n\
			}\n\
\n\
			let speeds = [];\n\
			// Loop through the parent keys\n\
			Object.keys(objValue).forEach(parentKey => {\n\
				const parentObj = objValue[parentKey];\n\
				// Array to store fan keys and values\n\
				const fanKeys = [];\n\
				// Call the recursive function to find fan keys and values\n\
				findFanKeys(parentObj, fanKeys);\n\
				// Sort the fan keys\n\
				fanKeys.sort();\n\
				// Process each fan key and value\n\
				fanKeys.forEach(({ key: fanKey, value: fanSpeed }) => {\n\
				try {\n\
					const fan = fanKey.charAt(0).toUpperCase() + fanKey.slice(1); // Capitalize the first letter of fanKey\n\
					speeds.push(\`\${fan}:&nbsp;\${fanSpeed} RPM\`);\n\
				} catch(e) {\n\
					console.error(\`Error retrieving fan speed for \${fanKey} in \${parentKey}:\`, e); // Debug: Log specific error\n\
				}\n\
				});\n\
			});\n\
			return '<div style=\"text-align: left; margin-left: 28px;\">' + (speeds.length > 0 ? speeds.join(' | ') : 'N/A') + '</div>';\n\
		}\n\
	},
		}" "$PVE_MANAGER_LIB_JS_FILE"
		fi

		if [ $ENABLE_RAM_TEMP = true ]; then
			# Add Ram temperature display
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a;
				/items:/!{N;ba;}
				:b;
				/'thermal.*},/!{N;bb;}
				a\
				\\
	{\n\
		xtype: 'box',\n\
		colspan: 2,\n\
		html: gettext('RAM'),\n\
	},\n\
	{\n\
		itemId: 'thermalRam',\n\
		colspan: 2,\n\
		printBar: false,\n\
		title: gettext('Thermal State'),\n\
		iconCls: 'fa fa-fw fa-thermometer-half',\n\
		textField: 'sensorsOutput',\n\
		renderer: function(value) {\n\
			const cpuTempHelper = Ext.create('PVE.mod.TempHelper', {srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: PVE.mod.TempHelper.CELSIUS});\n\
			// Make SODIMM unique keys\n\
			value = value.split('\\\n'); // Split by newlines\n\
			for (let i = 0; i < value.length; i++) {\n\
				// Check if the current line contains 'SODIMM'\n\
				if (value[i].includes('SODIMM') && i + 1 < value.length) {\n\
					// Extract the number '3' following 'temp' from the next line (e.g., "temp3_input": 25.000)\n\
					let nextLine = value[i + 1];\n\
					let match = nextLine.match(/\"temp(\\\d+)_input\": (\\\d+\\\.\\\d+)/);\n\
\n\
					if (match) {\n\
						let number = match[1]; // Extracted number\n\
						// Replace the current line with SODIMM by the extracted number\n\
						value[i] = value[i].replace('SODIMM', \`SODIMM\${number}\`);\n\
					}\n\
				}\n\
			}\n\
			value = value.join('\\\n'); // Reverse line split\n\
\n\
			let objValue;\n\
			try {\n\
				objValue = JSON.parse(value) || {};\n\
			} catch(e) {\n\
				objValue = {};\n\
			}\n\
\n\
			// Recursive function to find ram keys and values\n\
			function findRamKeys(obj, ramKeys, parentKey = null) {\n\
				Object.keys(obj).forEach(key => {\n\
				const value = obj[key];\n\
				if (typeof value === 'object' && value !== null) {\n\
					// If the value is an object, recursively call the function\n\
					findRamKeys(value, ramKeys, key);\n\
				} else if (/^temp\\\d+_input$/.test(key) && parentKey && parentKey.startsWith(\"SODIMM\")) {\n\
					if (value !== 0) {\n\
						ramKeys.push({ key: parentKey, value: value});\n\
					}\n\
				}\n\
				});\n\
			}\n\
\n\
			let ramTemps = [];\n\
			// Loop through the parent keys\n\
			Object.keys(objValue).forEach(parentKey => {\n\
				const parentObj = objValue[parentKey];\n\
				// Array to store ram keys and values\n\
				const ramKeys = [];\n\
				// Call the recursive function to find ram keys and values\n\
				findRamKeys(parentObj, ramKeys);\n\
				// Sort the ramKeys keys\n\
				ramKeys.sort();\n\
				// Process each ram key and value\n\
				ramKeys.forEach(({ key: ramKey, value: ramTemp }) => {\n\
				try {\n\
					ram = ramKey.replace('SODIMM', 'SODIMM ');\n\
					ramTemps.push(\`\${ram}:&nbsp\${ramTemp}\${cpuTempHelper.getUnit()}\`);\n\
				} catch(e) {\n\
					console.error(\`Error retrieving Ram Temp for \${ramTemps} in \${parentKey}:\`, e); // Debug: Log specific error\n\
				}\n\
				});\n\
			});\n\
			return '<div style=\"text-align: left; margin-left: 28px;\">' + (ramTemps.length > 0 ? ramTemps.join(' | ') : 'N/A') + '</div>';\n\
		}\n\
	},
		}" "$PVE_MANAGER_LIB_JS_FILE"
		fi

		# Add an empty line to separate modified items as a visual group
		# NOTE: Check for the presence of items in the reverse order of display
		local lastItemId=""
		if [ $ENABLE_HDD_TEMP = true ]; then
			lastItemId="thermalHdd"
		elif [ $ENABLE_NVME_TEMP = true ]; then
			lastItemId="thermalNvme"
		elif [ $ENABLE_FAN_SPEED = true ]; then
			lastItemId="speedFan"
		else
			lastItemId="thermalCpu"
		fi

		if [ -n "$lastItemId" ]; then
			sed -i "/^Ext.define('PVE.node.StatusView',/ {
			:a;
			/^.*{.*'$lastItemId'.*},/!{N;ba;}
			a\
			\\
	{\n\
		xtype: 'box',\n\
		colspan: 2,\n\
		padding: '0 0 20 0',\n\
	},
		}" "$PVE_MANAGER_LIB_JS_FILE"
		fi

		# Move the node summary box into its own container
		sed -i "/^\s*nodeStatus: nodeStatus,/ {
			:a
			/items: \[/ !{N;ba;}
			a\
			\\
		{\n\
			xtype: 'container',\n\
			itemId: 'summarycontainer',\n\
			layout: 'column',\n\
			minWidth: 700,\n\
			defaults: {\n\
				minHeight: 350,\n\
				padding: 5,\n\
				columnWidth: 1,\n\
			},\n\
			items: [\n\
				nodeStatus,\n\
			]\n\
		},
		}" "$PVE_MANAGER_LIB_JS_FILE"

		# Deactivate the original box instance
		sed -i "/^\s*nodeStatus: nodeStatus,/ {
			:a
			/itemId: 'itemcontainer',/ !{N;ba;}
			n;
			:b
			/nodeStatus,/ !{N;bb;}
			s/nodeStatus/\/\/nodeStatus/
		}" "$PVE_MANAGER_LIB_JS_FILE"

		msg "Sensor display items added to the summary panel in \"$PVE_MANAGER_LIB_JS_FILE\"."

		restart_proxy

		msg "Installation completed."

		info "Clear the browser cache to ensure all changes are visualized."
	else
		warn "Sensor display items already added to the summary panel in \"$PVE_MANAGER_LIB_JS_FILE\"."
	fi
}

# Function to uninstall the modification
function uninstall_mod {
	msg "\nRestoring modified files..."
	# Find the latest Nodes.pm file using the find command
	local latest_nodes_pm=$(find "$BACKUP_DIR" -name "Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_nodes_pm" ]; then
		# Remove the latest Nodes.pm file
		cp "$latest_nodes_pm" "$NODES_PM_FILE"
		msg "Copied latest backup to $NODES_PM_FILE."
	else
		warn "No Nodes.pm files found."
	fi

	# Find the latest pvemanagerlib.js file using the find command
	local latest_pvemanagerlibjs=$(find "$BACKUP_DIR" -name "pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_pvemanagerlibjs" ]; then
		# Remove the latest pvemanagerlib.js file
		cp "$latest_pvemanagerlibjs" "$PVE_MANAGER_LIB_JS_FILE"
		msg "Copied latest backup to \"$PVE_MANAGER_LIB_JS_FILE\"."
	else
		warn "No pvemanagerlib.js files found."
	fi

	if [ -n "$latest_nodes_pm" ] || [ -n "$latest_pvemanagerlibjs" ]; then
		# At least one of the variables is not empty, restart the proxy
		restart_proxy
	fi
}

function restart_proxy {
	# Restart pveproxy
	msg "\nRestarting PVE proxy..."
	systemctl restart pveproxy
}

function save_sensors_data {
	# Check if DEBUG_SAVE_PATH exists and is writable
	if [[ ! -d "$DEBUG_SAVE_PATH" || ! -w "$DEBUG_SAVE_PATH" ]]; then
		err "Directory $DEBUG_SAVE_PATH does not exist or is not writable. No file could be saved."
		return
	fi

	# Check if command exists
	if (command -v sensors &>/dev/null); then
		# Save sensors output
		local filepath="${DEBUG_SAVE_PATH}/${DEBUG_SAVE_FILENAME}"
		msg "Sensors data will be saved in $filepath"

		# Prompt user for confirmation
		local choiceContinue=$(ask "Do you wish to continue? (y/n)")
		case "$choiceContinue" in
			[yY])
				sensors -j >"$filepath"
				msgb "Sensors data saved in $filepath."
				;;
			*)
				warn "Operation cancelled by user."
				;;
		esac
	else
		err "Sensors is not installed. No file could be saved."
	fi
}

# Process the arguments using a while loop and a case statement
executed=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		install)
			executed=$(($executed + 1))
			msgb "\nInstalling the Proxmox VE sensors display mod..."
			install_packages
			install_mod
			echo # add a new line
			;;
		uninstall)
			executed=$(($executed + 1))
			msgb "\nUninstalling the Proxmox VE sensors display mod..."
			uninstall_mod
			echo # add a new line
			;;
		save-sensors-data)
			executed=$(($executed + 1))
			msgb "\nSaving current sensor readings in a file for debugging..."
			save_sensors_data
			echo # add a new line
			;;
	esac
	shift
done

# If no arguments were provided or all arguments have been processed, print the usage message
if [[ $executed -eq 0 ]]; then
	usage
fi