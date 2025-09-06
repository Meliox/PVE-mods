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

# Overwrite default backup location
BACKUP_DIR=""

##################### DO NOT EDIT BELOW #######################
# Only to be used to debug on other systems. Save the "sensor -j" output into a json file.
# Information will be loaded for script configuration and presented in Proxmox.

# DEV NOTE: lm-sensors version >3.6.0 breakes properly formatted JSON output using 'sensors -j'. This implements a workaround using uses a python3 for formatting

DEBUG_REMOTE=true
DEBUG_JSON_FILE="/tmp/sensordata.json"
DEBUG_UPS_FILE="/tmp/upsc.txt"

# This script's working directory
SCRIPT_CWD="$(dirname "$(readlink -f "$0")")"

# Debug location
JSON_EXPORT_DIRECTORY="$SCRIPT_CWD"
JSON_EXPORT_FILENAME="sensorsdata.json"

# File paths
PVE_MANAGER_LIB_JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
NODES_PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"

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

# System checks
function check_root_privileges() {
	[[ $EUID -eq 0 ]] || err "This script must be run as root. Please run it with 'sudo $0'."
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
		sensorsOutput=$(sensors -j 2>/dev/null | python3 -m json.tool)
	fi

	if [ $? -ne 0 ]; then
		err "Sensor output error.\n\nCommand output:\n${sensorsOutput}\n\nExiting...\n"
	fi

	# Check if CPU is part of known list for autoconfiguration
	msg "\nDetecting support for CPU temperature sensors..."
	supportedCPU=false
	for item in "${KNOWN_CPU_SENSORS[@]}"; do
			if (echo "$sensorsOutput" | grep -q "$item"); then
					echo $item
					supportedCPU=true
			fi
	done

	# Prompt user for which CPU temperature to use
	if [ $supportedCPU = true ]; then
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
							# If the user enters an invalid input, print an warning message and retry as>
							warn "Invalid input."
							continue
							;;
				esac
				break
		done
		SENSORS_DETECTED=true
	else
			warn "No CPU temperature sensors found."
	fi

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

	# Prompt user for enabling UPS
	local choiseEnableUPS=$(ask "Do you wish to enable information from an attached UPS (requires configured UPS server and installed UPS client from Network UPS Tools already configured beforehand). (Y/n)")
	case "$choiseEnableUPS" in
		[yY] | "")
			# Test the connection using upsc command
			if [ $DEBUG_REMOTE = true ]; then
				upsOutput=$(cat $DEBUG_UPS_FILE)
				echo "Remote debugging is used. UPS readings from dump file $DEBUG_UPS_FILE will be used."
				upsConnection="DEBUG_UPS"
			else
				# Prompt user for UPS connection details
				upsConnection=$(ask "Enter connection details for the UPS (e.g., upsname[@hostname[:port]])")

				if (! command -v upsc &>/dev/null); then
					err "The 'upsc' command is not available. Please install the 'nut-client' package and ensure it is configured correctly. Exiting..."
				fi

				upsOutput=$(upsc "$upsConnection" 2>&1)
			fi

			# Check for device.model in the output to confirm successful connection
			if (echo "$upsOutput" | grep -q "device.model:"); then
				# Extract the model name
				modelName=$(echo "$upsOutput" | grep "device.model:" | cut -d':' -f2- | xargs)
				ENABLE_UPS=true
				echo "Successfully connected to UPS model: $modelName at $upsConnection."
				info "UPS information will be displayed..."
			else
				warn "Failed to connect to UPS at '$upsConnection'. No valid UPS model found."
				warn "Error: $upsOutput"
				ENABLE_UPS=false
			fi

			;;
		[nN])
			ENABLE_UPS=false
			info "UPS information will NOT be displayed..."
			;;
		*)
			warn "Invalid selection. UPS information will not be displayed."
			ENABLE_UPS=false
			;;
	esac
	echo ""

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
	check_root_privileges

	if [[ -n $(cat $NODES_PM_FILE | grep -e "$res->{sensorsOutput}") ]] && [[ -n $(cat $NODES_PM_FILE | grep -e "$res->{systemInfo}") ]]; then
		err "Mod is already installed. Uninstall existing before installing."
	fi

	msg "\nPreparing mod installation..."
	configure
	perform_backup

	if [ $SENSORS_DETECTED = true ]; then
		local sensorsCmd
		if [ $DEBUG_REMOTE = true ]; then
			sensorsCmd="cat \"$DEBUG_JSON_FILE\""
		else
			# WTF: sensors -f used for Fahrenheit breaks the fan speeds :|
			#local sensorsCmd=$([[ "$TEMP_UNIT" = "F" ]] && echo "sensors -j -f" || echo "sensors -j")
			sensorsCmd="sensors -j 2>/dev/null | python3 -m json.tool"
		fi
		# Insert sensor data collection and JSON sanitization before the disk info line
		sed -i '/my \$dinfo = df('\''\/'\'', 1);/i\
		\
		# Collect sensor data from lm-sensors\
		$res->{sensorsOutput} = `'"$sensorsCmd"'`;\
		\
		# Sanitize JSON output to handle common lm-sensors parsing issues\
		# Replace ERROR lines with placeholder values\
		$res->{sensorsOutput} =~ s/ERROR:.+\\s(\\w+):\\s(.+)/\\"$1\\": 0.000,/g;\
		$res->{sensorsOutput} =~ s/ERROR:.+\\s(\\w+)!/\\"$1\\": 0.000,/g;\
		\
		# Remove trailing commas before closing braces\
		$res->{sensorsOutput} =~ s/,\\s*(\})/$1/g;\
		\
		# Replace NaN values with null for valid JSON\
		$res->{sensorsOutput} =~ s/\\bNaN\\b/null/g;\
		\
		# Fix duplicate SODIMM keys by appending temperature sensor number\
		# This prevents JSON key overwrites when multiple SODIMM sensors exist\
		# Example: "SODIMM":{"temp3_input":34.0} becomes "SODIMM3":{"temp3_input":34.0}\
		$res->{sensorsOutput} =~ s/\\"SODIMM\\":\\{\\"temp(\\d+)_input\\"/\\"SODIMM$1\\":\\{\\"temp$1_input\\"/g;\
		' "$NODES_PM_FILE"	
		msg "Sensors' output added to \"$NODES_PM_FILE\"."
	fi

	if [ $ENABLE_UPS = true ]; then
		local upsCmd
		if [ $DEBUG_REMOTE = true ]; then
			upsCmd="cat \"$DEBUG_UPS_FILE\""
		else
			upsCmd="upsc \"$upsConnection\" 2>/dev/null"
		fi

		# Insert UPS data collection before the disk info line
		sed -i "/my \$dinfo = df('\/', 1);/i\\
		\\
		# Collect UPS status information\\
		\$res->{upsc} = \\\`$upsCmd\\\`;\\
		" "$NODES_PM_FILE"
		
		msg "UPS output added to \"$NODES_PM_FILE\"."
	fi

	if [ $ENABLE_SYSTEM_INFO = true ]; then
		local systemInfoCmd=$(dmidecode -t ${SYSTEM_INFO_TYPE} | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print $1": "$2}' | awk '{$1=$1};1' | sed 's/$/ |/' | paste -sd " " - | sed 's/ |$//')
		sed -i "/my \$dinfo = df('\/', 1);/i\\\t\t\$res->{systemInfo} = \"$(echo "$systemInfoCmd")\";\n" "$NODES_PM_FILE"
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
				let bTdie = false;\n\
				cpuKeysA.forEach((cpuKey, cpuIndex) => {\n\
					let items = objValue[cpuKey];\n\
					bTccd = Object.keys(items).findIndex(item => { return String(item).startsWith('Tccd'); }) >= 0;\n\
					bTctl = Object.keys(items).findIndex(item => { return String(item).startsWith('Tctl'); }) >= 0;\n\
					bTdie = Object.keys(items).findIndex(item => { return String(item).startsWith('Tdie'); }) >= 0;\n\
				});\n\
				if (bTccd && bTctl && '$CPU_TEMP_TARGET' == 'Core') {\n\
					AMDPackagePrefix = 'Tccd';\n\
					AMDPackageCaption = 'Chiplet';\n\
				} else if (bTdie) {\n\
					AMDPackagePrefix = 'Tdie';\n\
					AMDPackageCaption = 'Temp';\n\
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
				const itemKeys = Object.keys(items).filter(item => { return String(item).includes(cpuItemPrefix); });\n\
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
							let tempIndex = coreKey.match(\/(?:P\\\s+Core|E\\\s+Core|Core)\\\s*(\\\d+)\/);\n\
							if (tempIndex !== null && tempIndex.length > 1) {\n\
								tempIndex = tempIndex[1];\n\
								let coreType = coreKey.startsWith('P Core') ? 'P Core' :\n\
											   coreKey.startsWith('E Core') ? 'E Core' :\n\
											   cpuTempCaption;\n\
								tempStr = \`\${coreType}&nbsp;\${tempIndex}:&nbsp;<span style=\"\${tempStyle}\">\${Ext.util.Format.number(tempVal, formatTemp)}\${cpuTempHelper.getUnit()}</span>\`;\n\
							} else {\n\
								// fallback for CPUs which do not have a core index\n\
								let coreType = coreKey.startsWith('P Core') ? 'P Core' :\n\
									coreKey.startsWith('E Core') ? 'E Core' :\n\
									cpuTempCaption;\n\
								tempStr = \`\${coreType}:&nbsp;<span style=\"\${tempStyle}\">\${Ext.util.Format.number(tempVal, formatTemp)}\${cpuTempHelper.getUnit()}</span>\`;\n\
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

		if [ $ENABLE_UPS = true ]; then
			local TEMP_JS_FILE="/tmp/ups_widget.js"
			generate_ups_widget $TEMP_JS_FILE

			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a
				/items:/!{N;ba;}
				:b
				/'thermal.*},/!{N;bb;}
				r /tmp/ups_widget.js
			}" "$PVE_MANAGER_LIB_JS_FILE"

			rm $TEMP_JS_FILE
		fi

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
			local TEMP_JS_FILE="/tmp/ram_widget.js"
			generate_ram_widget $TEMP_JS_FILE

			sed -i "/^Ext.define('PVE.node.StatusView',/ {
				:a
				/items:/!{N;ba;}
				:b
				/'thermal.*},/!{N;bb;}
				r $TEMP_JS_FILE
			}" "$PVE_MANAGER_LIB_JS_FILE"

			rm $TEMP_JS_FILE
		fi

		# Add an empty line to separate modified items as a visual group
		# NOTE: Check for the presence of items in the reverse order of display
		local lastItemId=""
		if [ $ENABLE_UPS = true ]; then
			lastItemId="upsc"			
		elif [ $ENABLE_HDD_TEMP = true ]; then
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

generate_ram_widget() {
	#region ram widget heredoc
    cat > "$1" <<'EOF'
	{
		xtype: 'box',
		colspan: 2,
		html: gettext('RAM'),
	},
	{
		itemId: 'thermalRam',
		colspan: 2,
		printBar: false,
		title: gettext('Thermal State'),
		iconCls: 'fa fa-fw fa-thermometer-half',
		textField: 'sensorsOutput',
		renderer: function(value) {
			const cpuTempHelper = Ext.create('PVE.mod.TempHelper', {srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: PVE.mod.TempHelper.CELSIUS});
			// Make SODIMM unique keys
			value = value.split('\n'); // Split by newlines
			for (let i = 0; i < value.length; i++) {
				// Check if the current line contains 'SODIMM'
				if (value[i].includes('SODIMM') && i + 1 < value.length) {
					// Extract the number '3' following 'temp' from the next line (e.g., "temp3_input": 25.000)
					let nextLine = value[i + 1];
					let match = nextLine.match(/"temp(\d+)_input": (\d+\.\d+)/);

					if (match) {
						let number = match[1]; // Extracted number
						// Replace the current line with SODIMM by the extracted number
						value[i] = value[i].replace('SODIMM', `SODIMM${number}`);
					}
				}
			}
			value = value.join('\n'); // Reverse line split

			let objValue;
			try {
				objValue = JSON.parse(value) || {};
			} catch(e) {
				objValue = {};
			}

			// Recursive function to find ram keys and values
			function findRamKeys(obj, ramKeys, parentKey = null) {
				Object.keys(obj).forEach(key => {
				const value = obj[key];
				if (typeof value === 'object' && value !== null) {
					// If the value is an object, recursively call the function
					findRamKeys(value, ramKeys, key);
				} else if (/^temp\d+_input$/.test(key) && parentKey && parentKey.startsWith("SODIMM")) {
					if (value !== 0) {
						ramKeys.push({ key: parentKey, value: value});
					}
				}
				});
			}

			let ramTemps = [];
			// Loop through the parent keys
			Object.keys(objValue).forEach(parentKey => {
				const parentObj = objValue[parentKey];
				// Array to store ram keys and values
				const ramKeys = [];
				// Call the recursive function to find ram keys and values
				findRamKeys(parentObj, ramKeys);
				// Sort the ramKeys keys
				ramKeys.sort();
				// Process each ram key and value
				ramKeys.forEach(({ key: ramKey, value: ramTemp }) => {
				try {
					ram = ramKey.replace('SODIMM', 'SODIMM ');
					ramTemps.push(`${ram}:&nbsp${ramTemp}${cpuTempHelper.getUnit()}`);
				} catch(e) {
					console.error(`Error retrieving Ram Temp for ${ramTemps} in ${parentKey}:`, e); // Debug: Log specific error
				}
				});
			});
			return '<div style="text-align: left; margin-left: 28px;">' + (ramTemps.length > 0 ? ramTemps.join(' | ') : 'N/A') + '</div>';
		}
	},
EOF
	#endregion ram widget heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate ram widget code" >&2
        exit 1
    fi
}

generate_ups_widget() {
	#region UPS widget heredoc
    cat > "$1" <<'EOF'
	{
		xtype: 'box',
		colspan: 2,
		html: gettext('UPS'),
	},
	{
		itemId: 'upsc',
		colspan: 2,
		printBar: false,
		title: gettext('Device'),
		iconCls: 'fa fa-fw fa-battery-three-quarters',
		textField: 'upsc',
		renderer: function(value) {
			let objValue = {};
			try {
				// Parse the UPS data
				if (typeof value === 'string') {
					const lines = value.split('\n');
					lines.forEach(line => {
						const colonIndex = line.indexOf(':');
						if (colonIndex > 0) {
							const key = line.substring(0, colonIndex).trim();
							const val = line.substring(colonIndex + 1).trim();
							objValue[key] = val;
						}
					});
				} else if (typeof value === 'object') {
					objValue = value || {};
				}
			} catch(e) {
				objValue = {};
			}

			// If objValue is null or empty, return N/A
			if (!objValue || Object.keys(objValue).length === 0) {
				return '<div style="text-align: right;"><span style="color: white;">N/A</span></div>';
			}

			// Helper function to get status color
			function getStatusColor(status) {
				if (!status) return '#999';
				const statusUpper = status.toUpperCase();
				if (statusUpper.includes('OL')) return 'white'; // White for online
				if (statusUpper.includes('OB')) return '#d9534f'; // Red for on battery
				if (statusUpper.includes('LB')) return '#d9534f'; // Red for low battery
				return '#f0ad4e'; // Orange for other states
			}

			// Helper function to get load/charge color
			function getPercentageColor(value, isLoad = false) {
				if (!value || isNaN(value)) return '#999';
				const num = parseFloat(value);
				if (isLoad) {
					if (num >= 80) return '#d9534f'; // Red for high load
					if (num >= 60) return '#f0ad4e'; // Orange for medium load
					return 'white'; // White for low load
				} else {
					// For battery charge
					if (num <= 20) return '#d9534f'; // Red for low charge
					if (num <= 50) return '#f0ad4e'; // Orange for medium charge
					return 'white'; // White for good charge
				}
			}

			// Helper function to format runtime
			function formatRuntime(seconds) {
				if (!seconds || isNaN(seconds)) return 'N/A';
				const mins = Math.floor(seconds / 60);
				const secs = seconds % 60;
				return `${mins}m ${secs}s`;
			}

			// Extract key UPS information
			const batteryCharge = objValue['battery.charge'];
			const batteryRuntime = objValue['battery.runtime'];
			const inputVoltage = objValue['input.voltage'];
			const upsLoad = objValue['ups.load'];
			const upsStatus = objValue['ups.status'];
			const upsModel = objValue['ups.model'] || objValue['device.model'];
			const testResult = objValue['ups.test.result'];
			const batteryChargeLow = objValue['battery.charge.low'];
			const batteryRuntimeLow = objValue['battery.runtime.low'];
			const upsRealPowerNominal = objValue['ups.realpower.nominal'];
			const batteryMfrDate = objValue['battery.mfr.date'];

			// Build the status display
			let displayItems = [];

			// First line: Model info
			let modelLine = '';
			if (upsModel) {
				modelLine = `<span style="color: white;">${upsModel}</span>`;
			} else {
				modelLine = `<span style="color: white;">N/A</span>`;
			}
			displayItems.push(modelLine);

			// Main status line with all metrics
			let statusLine = '';

			// Status
			if (upsStatus) {
				const statusUpper = upsStatus.toUpperCase();
				let statusText = 'Unknown';
				let statusColor = '#f0ad4e';

				if (statusUpper.includes('OL')) {
					statusText = 'Online';
					statusColor = 'white'; // White for good status
				} else if (statusUpper.includes('OB')) {
					statusText = 'On Battery';
					statusColor = '#d9534f'; // Red for on battery
				} else if (statusUpper.includes('LB')) {
					statusText = 'Low Battery';
					statusColor = '#d9534f'; // Red for low battery
				} else {
					statusText = upsStatus;
					statusColor = '#f0ad4e'; // Orange for unknown status
				}

				statusLine += `Status: <span style="color: ${statusColor};">${statusText}</span>`;
			} else {
				statusLine += `Status: <span style="color: white;">N/A</span>`;
			}

			// Battery charge
			if (statusLine) statusLine += ' | ';
			if (batteryCharge) {
				const chargeColor = getPercentageColor(batteryCharge, false);
				statusLine += `Battery: <span style="color: ${chargeColor};">${batteryCharge}%</span>`;
			} else {
				statusLine += `Battery: <span style="color: white;">N/A</span>`;
			}

			// Load percentage
			if (statusLine) statusLine += ' | ';
			if (upsLoad) {
				const loadColor = getPercentageColor(upsLoad, true);
				statusLine += `Load: <span style="color: ${loadColor};">${upsLoad}%</span>`;
			} else {
				statusLine += `Load: <span style="color: white;">N/A</span>`;
			}

			// Runtime
			if (statusLine) statusLine += ' | ';
			if (batteryRuntime) {
				const runtime = parseInt(batteryRuntime);
				const runtimeLowThreshold = batteryRuntimeLow ? parseInt(batteryRuntimeLow) : 600;
				let runtimeColor = 'white';
				if (runtime <= runtimeLowThreshold / 2) runtimeColor = '#d9534f'; // Red if less than half of low threshold
				else if (runtime <= runtimeLowThreshold) runtimeColor = '#f0ad4e'; // Orange if at low threshold

				statusLine += `Runtime: <span style="color: ${runtimeColor};">${formatRuntime(runtime)}</span>`;
			} else {
				statusLine += `Runtime: <span style="color: white;">N/A</span>`;
			}

			// Input voltage
			if (statusLine) statusLine += ' | ';
			if (inputVoltage) {
				statusLine += `Input: <span style="color: white;">${parseFloat(inputVoltage).toFixed(0)}V</span>`;
			} else {
				statusLine += `Input: <span style="color: white;">N/A</span>`;
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
				statusLine += `Output: <span style="color: white;">${actualWattage}W</span>`;
			} else {
				statusLine += `Output: <span style="color: white;">N/A</span>`;
			}

			displayItems.push(statusLine);

			// Combined battery and test line
			let batteryTestLine = '';
			if (batteryMfrDate) {
				batteryTestLine += `<span style="color: white;">Battery MFD: ${batteryMfrDate}</span>`;
			} else {
				batteryTestLine += `<span style="color: white;">Battery MFD: N/A</span>`;
			}

			if (testResult && !testResult.toLowerCase().includes('no test')) {
				const testColor = testResult.toLowerCase().includes('passed') ? 'white' : '#d9534f';
				batteryTestLine += ` | <span style="color: ${testColor};">Test: ${testResult}</span>`;
			} else {
				batteryTestLine += ` | <span style="color: white;">Test: N/A</span>`;
			}

			displayItems.push(batteryTestLine);

			// Format the final output
			return '<div style="text-align: right;">' + displayItems.join('<br>') + '</div>';
		}
	},
EOF
	#endregion UPS widget heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate UPS widget code" >&2
        exit 1
    fi
}

# Function to uninstall the modification
function uninstall_mod {
	check_root_privileges

	if [[ -z $(grep -e "$res->{sensorsOutput}" "$NODES_PM_FILE") ]] && [[ -z $(grep -e "$res->{systemInfo}" "$NODES_PM_FILE") ]]; then
		err "Mod is not installed."
	fi

	set_backup_directory
	msg "\nRestoring modified files..."

	# Find the latest Nodes.pm file using the find command
	local latest_nodes_pm=$(find "$BACKUP_DIR" -name "Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_nodes_pm" ]; then
		# Remove the latest Nodes.pm file
		cp "$latest_nodes_pm" "$NODES_PM_FILE"
		msg "Restoring latest Nodes.pm from backup: $latest_nodes_pm to \"$NODES_PM_FILE\"."
	else
		warn "No Nodes.pm backup files found."
	fi

	# Find the latest pvemanagerlib.js file using the find command
	local latest_pvemanagerlibjs=$(find "$BACKUP_DIR" -name "pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_pvemanagerlibjs" ]; then
		# Remove the latest pvemanagerlib.js file
		cp "$latest_pvemanagerlibjs" "$PVE_MANAGER_LIB_JS_FILE"
		msg "Restoring latest pvemanagerlib.js from backup: $latest_pvemanagerlibjs to \"$PVE_MANAGER_LIB_JS_FILE\"."
	else
		warn "No pvemanagerlib.js backup files found."
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
	# Check if JSON_EXPORT_DIRECTORY exists and is writable
	if [[ ! -d "$JSON_EXPORT_DIRECTORY" || ! -w "$JSON_EXPORT_DIRECTORY" ]]; then
		err "Directory $JSON_EXPORT_DIRECTORY does not exist or is not writable. No file could be saved."
		return
	fi

	# Check if command exists
	if (command -v sensors &>/dev/null); then
		# Save sensors output
		local filepath="${JSON_EXPORT_DIRECTORY}/${DEBUG_SAVE_FILENAME}"
		msg "Sensors data will be saved in $filepath"

		# Prompt user for confirmation
		local choiceContinue=$(ask "Do you wish to continue? (y/n)")
		case "$choiceContinue" in
			[yY])
				sensors -j 2>/dev/null | python3 -m json.tool >"$filepath"
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

function set_backup_directory {
	# Check if the BACKUP_DIR variable is set, if not, use the default backup
	if [[ -z "$BACKUP_DIR" ]]; then
		# If not set, use the default backup directory, which is based on the home directory and PVE-MODS
		BACKUP_DIR="$HOME/PVE-MODS"
		msg "Using default backup directory: $BACKUP_DIR"
	else
		# If set, ensure it is a valid directory
		if [[ ! -d "$BACKUP_DIR" ]]; then
			err "The specified backup directory does not exist: $BACKUP_DIR"
		fi
		msg "Using custom backup directory: $BACKUP_DIR"
	fi
}

function create_backup_directory {
	set_backup_directory

	# Create the backup directory if it does not exist
	if [[ ! -d "$BACKUP_DIR" ]]; then
		mkdir -p "$BACKUP_DIR" 2>/dev/null || {
			err "Failed to create backup directory: $BACKUP_DIR. Please check permissions."
		}
		msg "Created backup directory: $BACKUP_DIR"
	else
		msg "Backup directory already exists: $BACKUP_DIR"
	fi
}

function create_file_backup() {
    local source_file="$1"
    local timestamp="$2"
    local filename
    
    filename=$(basename "$source_file")
    local backup_file="$BACKUP_DIR/${filename}.$timestamp"
    
    [[ -f "$source_file" ]] || err "Source file does not exist: $source_file"
    [[ -r "$source_file" ]] || err "Cannot read source file: $source_file"
       
    cp "$source_file" "$backup_file" || err "Failed to create backup: $backup_file"
    
    # Verify backup integrity
    if ! cmp -s "$source_file" "$backup_file"; then
        err "Backup verification failed for: $backup_file"
    fi
    
    msg "Created backup: $backup_file"
}

function perform_backup {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
    create_backup_directory
    create_file_backup "$NODES_PM_FILE" "$timestamp"
    create_file_backup "$PVE_MANAGER_LIB_JS_FILE" "$timestamp"
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