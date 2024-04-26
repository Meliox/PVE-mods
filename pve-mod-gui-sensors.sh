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
pvemanagerlibjs="/usr/share/pve-manager/js/pvemanagerlib.js"
nodespm="/usr/share/perl5/PVE/API2/Nodes.pm"

###############################################

# Helper functions
function msg {
	echo -e "\e[0m$1\e[0m"
}

#echo message in bold
function msgb {
	echo -e "\e[1m$1\e[0m"
}

function warn {
	echo -e "\e[0;33m[warning] $1\e[0m"
}

function err {
	echo -e "\e[0;31m[error] $1\e[0m"
	exit 1
}
# End of helper functions

# Function to display usage information
function usage {
	msgb "\nUsage:\n$0 [install | uninstall]\n"
	exit 1
}

# Define a function to install packages
function install_packages {
	# Check if the 'sensors' command is available on the system
	if (! command -v sensors &>/dev/null); then
		# If the 'sensors' command is not available, prompt the user to install lm-sensors
		read -p "lm-sensors is not installed. Would you like to install it? (y/n) " choice
		case "$choice" in
			y | Y)
				# If the user chooses to install lm-sensors, update the package list and install the package
				apt-get update
				apt-get install lm-sensors
				;;
			n | N)
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
	local sensorsOutput=$(sensors -j)
	if [ $? -ne 0 ]; then
		err "Sensor output error.\n\nCommand output:\n${sensorsOutput}\n\nExiting...\n"
	fi

	# Check if HDD/SSD data is installed
	msg "\nDetecting support for HDD/SDD temperature sensors..."
	if (lsmod | grep -wq "drivetemp"); then
		# Check if SDD/HDD data is available
		if (echo "$sensorsOutput" | grep -q "drivetemp-scsi-"); then
			msg "Detected sensors:\n$(echo "$sensorsOutput" | grep -o '"drivetemp-scsi[^"]*"' | sed 's/"//g')"
			enableHddTemp=true
		else
			warn "Kernel module \"drivetemp\" is not installed. HDD/SDD temperatures will not be available."
			enableHddTemp=false
		fi
	else
		enableHddTemp=false
	fi

	# Check if NVMe data is available
	msg "\nDetecting support for NVMe temperature sensors..."
	if (echo "$sensorsOutput" | grep -q "nvme-"); then
		msg "Detected sensors:\n$(echo "$sensorsOutput" | grep -o '"nvme[^"]*"' | sed 's/"//g')"
		enableNvmeTemp=true
	else
		warn "No NVMe temperature sensors found."
		enableNvmeTemp=false
	fi

	# Check if CPU is part of known list for autoconfiguration
	msg "\nDetecting support for CPU temperature sensors..."
	for item in "${KNOWN_CPU_SENSORS[@]}"; do
		if (echo "$sensorsOutput" | grep -q "$item"); then
			case "$item" in
				"coretemp-"*)
					CPU_ADDRESS="$(echo "$sensorsOutput" | grep "$item" | sed 's/"//g;s/:{//;s/^\s*//')"
					CPU_ITEM_PREFIX="Core "
					CPU_TEMP_CAPTION="Core"
					break
					;;
				"k10temp-"*)
					CPU_ADDRESS="$(echo "$sensorsOutput" | grep "$item" | sed 's/"//g;s/:{//;s/^\s*//')"
					CPU_ITEM_PREFIX="Tccd"
					CPU_TEMP_CAPTION="Temp"
					break
					;;
				*)
					continue
					;;
			esac
		fi
	done

	if [ -n "$CPU_ADDRESS" ]; then
		msg "Detected sensor:\n$CPU_ADDRESS"
	fi

	# If cpu is not known, ask the user for input
	if [ -z "$CPU_ADDRESS" ]; then
		warn "Could not automatically detect the CPU temperature sensor. Please configure it manually."
		# Ask user for CPU information
		# Inform the user and prompt them to press any key to continue
		read -rsp $'Sensor output will be presented. Press any key to continue...\n' -n1 key

		# Print the output to the user
		msg "Sensor output:\n${sensorsOutput}"

		# Prompt the user for adapter name and item name
		read -p "Enter the CPU sensor address (e.g.: coretemp-isa-0000 or k10temp-pci-00c3): " CPU_ADDRESS
		read -p "Enter the CPU sensor input prefix (e.g.: Core or Tc): " CPU_ITEM_PREFIX
		read -p "Enter the CPU temperature caption (e.g.: Core or Temp): " CPU_TEMP_CAPTION
	fi

	if [[ -z "$CPU_ADDRESS" || -z "$CPU_ITEM_PREFIX" ]]; then
		warn "The CPU configuration is not complete. Temperatures will not be available."
	fi

	# Look for fan speeds
	msg "\nDetecting support for fan speeds..."
	if (echo "$sensorsOutput" | grep -q "fan[0-9]*_input"); then
		msg "Fan speeds detected:\n$(echo "$sensorsOutput" | grep -o 'fan[0-9]*_input[^"]*')"
		enableFanSpeed=true
	else
		warn "No fan speeds found."
		enableFanSpeed=false
	fi

	echo # add a new line
}

# Function to install the modification
function install_mod {
	msg "\nPreparing mod installation..."

	# Provide sensor configuration
	configure

	# Create backup of original files
	mkdir -p "$BACKUP_DIR"

	local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

	# Add new line to Nodes.pm file
	if [[ -z $(cat $nodespm | grep -e "$res->{sensorsOutput}") ]]; then
		# Create backup of original file
		cp "$nodespm" "$BACKUP_DIR/Nodes.pm.$timestamp"
		msg "Backup of \"$nodespm\" saved to \"$BACKUP_DIR/Nodes.pm.$timestamp\"."

		sed -i '/my $dinfo = df('\''\/'\'', 1);/i\'$'\t''$res->{sensorsOutput} = `sensors -j`;\n' "$nodespm"
		msg "Sensors' output added to \"$nodespm\"."
	else
		warn "Sensors' output already integrated in in \"$nodespm\"."
	fi

	# Add new item to the items array in PVE.node.StatusView
	if [[ -z $(cat "$pvemanagerlibjs" | grep -e "itemId: 'thermal[[:alnum:]]*'") ]]; then
		# Create backup of original file
		cp "$pvemanagerlibjs" "$BACKUP_DIR/pvemanagerlib.js.$timestamp"
		msg "Backup of \"$pvemanagerlibjs\" saved to \"$BACKUP_DIR/pvemanagerlib.js.$timestamp\"."

		# Expand space in StatusView
		sed -i "/Ext.define('PVE\.node\.StatusView'/,/\},/ {
			s/\(bodyPadding:\) '[^']*'/\1 '20 15 20 15'/
			s/height: [0-9]\+/minHeight: 360,\n\tflex: 1/
			s/\(tableAttrs:.*$\)/trAttrs: \{ valign: 'top' \},\n\t\1/
		}" "$pvemanagerlibjs"
		msg "Expanded space in \"$pvemanagerlibjs\"."

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
			const cpuAddress = \"$CPU_ADDRESS\";\n\
			const cpuItemPrefix = \"$CPU_ITEM_PREFIX\";\n\
			const cpuTempCaption = \"$CPU_TEMP_CAPTION\";\n\
			// display configuration\n\
			const itemsPerRow = $CPU_ITEMS_PER_ROW;\n\
			// ---\n\
			const objValue = JSON.parse(value);\n\
			if (objValue.hasOwnProperty(cpuAddress)) {\n\
				const items = objValue[cpuAddress];\n\
				const itemKeys = Object.keys(items).filter(item => { return String(item).startsWith(cpuItemPrefix); });\n\
				let temps = [];\n\
				itemKeys.forEach((coreKey) => {\n\
					try {\n\
						let tempVal = NaN, tempMax = NaN, tempCrit = NaN;\n\
						Object.keys(items[coreKey]).forEach((secondLevelKey) => {\n\
							if (secondLevelKey.endsWith('_input')) {\n\
								tempVal = parseFloat(items[coreKey][secondLevelKey]);\n\
							} else if (secondLevelKey.endsWith('_max')) {\n\
								tempMax = parseFloat(items[coreKey][secondLevelKey]);\n\
							} else if (secondLevelKey.endsWith('_crit')) {\n\
								tempCrit = parseFloat(items[coreKey][secondLevelKey]);\n\
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
								tempStr = \`\${cpuTempCaption}&nbsp;\${tempIndex}:&nbsp;<span style=\"\${tempStyle}\">\${tempVal}&deg;C</span>\`;\n\
							} else {\n\
								tempStr = \`\${cpuTempCaption}:&nbsp;\${tempVal}&deg;C\`;\n\
							}\n\
							temps.push(tempStr);\n\
						}\n\
					} catch (e) { /*_*/\n\
					}\n\
				});\n\
				const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? (itemsPerRow > 0 && (index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); });\n\
				return '<div style=\"text-align: left; margin-left: 28px;\">' + (result.length > 0 ? result.join('') : 'N/A') + '</div>';\n\
			}\n\
		}\n\
	},
		}" "$pvemanagerlibjs"

		#
		# NOTE: The following items will be added in reverse order
		#
		if [ $enableHddTemp = true ]; then
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
			// display configuration\n\
			const itemsPerRow = ${HDD_ITEMS_PER_ROW};\n\
			const objValue = JSON.parse(value);\n\
			// ---\n\
			const drvKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();\n\
			let temps = [];\n\
			drvKeys.forEach((drvKey, index) => {\n\
				try {\n\
					let tempVal = NaN, tempMax = NaN, tempCrit = NaN;\n\
					Object.keys(objValue[drvKey][sensorName]).forEach((secondLevelKey) => {\n\
						if (secondLevelKey.endsWith('_input')) {\n\
							tempVal = parseFloat(objValue[drvKey][sensorName][secondLevelKey]);\n\
						} else if (secondLevelKey.endsWith('_max')) {\n\
							tempMax = parseFloat(objValue[drvKey][sensorName][secondLevelKey]);\n\
						} else if (secondLevelKey.endsWith('_crit')) {\n\
							tempCrit = parseFloat(objValue[drvKey][sensorName][secondLevelKey]);\n\
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
						const tempStr = \`Drive&nbsp;\${index + 1}:&nbsp;<span style=\"\${tempStyle}\">\${tempVal}&deg;C</span>\`;\n\
						temps.push(tempStr);\n\
					}\n\
				} catch(e) { /*_*/ }\n\
			});\n\
			const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); });\n\
			return '<div style=\"text-align: left; margin-left: 28px;\">' + (result.length > 0 ? result.join('') : 'N/A') + '</div>';\n\
		}\n\
	},
		}" "$pvemanagerlibjs"
		fi

		if [ $enableNvmeTemp = true ]; then
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
			// display configuration\n\
			const itemsPerRow = ${NVME_ITEMS_PER_ROW};\n\
			// ---\n\
			const objValue = JSON.parse(value);\n\
			const nvmeKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();\n\
			let temps = [];\n\
			nvmeKeys.forEach((nvmeKey, index) => {\n\
				try {\n\
					let tempVal = NaN, tempMax = NaN, tempCrit = NaN;\n\
					Object.keys(objValue[nvmeKey][sensorName]).forEach((secondLevelKey) => {\n\
						if (secondLevelKey.endsWith('_input')) {\n\
							tempVal = parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]);\n\
						} else if (secondLevelKey.endsWith('_max')) {\n\
							tempMax = parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]);\n\
						} else if (secondLevelKey.endsWith('_crit')) {\n\
							tempCrit = parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]);\n\
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
						const tempStr = \`Drive&nbsp;\${index + 1}:&nbsp;<span style=\"\${tempStyle}\">\${tempVal}&deg;C</span>\`;\n\
						temps.push(tempStr);\n\
					}\n\
				} catch(e) { /*_*/ }\n\
			});\n\
			const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); });\n\
			return '<div style=\"text-align: left; margin-left: 28px;\">' + (result.length > 0 ? result.join('') : 'N/A') + '</div>';\n\
		}\n\
	},
			}" "$pvemanagerlibjs"
		fi

		if [ $enableNvmeTemp = true -o $enableHddTemp = true ]; then
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
		}" "$pvemanagerlibjs"
		fi

		if [ $enableFanSpeed = true ]; then
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
			const objValue = JSON.parse(value);\n\
			let speeds = [];\n\
\n\
			// Loop through the parent keys\n\
			Object.keys(objValue).forEach(parentKey => {\n\
				const parentObj = objValue[parentKey];\n\
\n\
				// Filter and sort fan keys for each parent object\n\
				const fanKeys = Object.keys(parentObj).filter(item => /^fan[0-9]+$/.test(item)).sort();\n\
\n\
				fanKeys.forEach((fanKey) => {\n\
					try {\n\
						const fanSpeed = parentObj[fanKey][\`\${fanKey}_input\`];\n\
						const fanNumber = fanKey.replace('fan', '');  // Extract fan number from the key\n\
						if (fanSpeed !== undefined) {\n\
							speeds.push(\`Fan&nbsp;\${fanNumber}:&nbsp;\${fanSpeed} RPM\`);\n\
						}\n\
					} catch(e) {\n\
						console.error(\`Error retrieving fan speed for \${fanKey} in \${parentKey}:\`, e);  // Debug: Log specific error\n\
					}\n\
				});\n\
			});\n\
\n\
			return '<div style=\"text-align: left; margin-left: 28px;\">' + (speeds.length > 0 ? speeds.join(' | ') : 'N/A') + '</div>';\n\
		}\n\
	},
		}" "$pvemanagerlibjs"
		fi

		# Add an empty line to separate modified items as a visual group
		# NOTE: Check for the presence of items in the reverse order of display
		local lastItemId=""
		if [ $enableHddTemp = true ]; then
			lastItemId="thermalHdd"
		elif [ $enableNvmeTemp = true ]; then
			lastItemId="thermalNvme"
		elif [ $enableFanSpeed = true ]; then
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
		}" "$pvemanagerlibjs"
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
		}" "$pvemanagerlibjs"

		# Deactivate the original box instance
		sed -i "/^\s*nodeStatus: nodeStatus,/ {
			:a
			/itemId: 'itemcontainer',/ !{N;ba;}
			n;
			:b
			/nodeStatus,/ !{N;bb;}
			s/nodeStatus/\/\/nodeStatus/
		}" "$pvemanagerlibjs"

		msg "Sensor display items added to the summary panel in \"$pvemanagerlibjs\"."

		restart_proxy

		msg "Installation completed"
	else
		warn "Sensor display items already added to the summary panel in \"$pvemanagerlibjs\"."
	fi
}

# Function to uninstall the modification
function uninstall_mod {
	msg "\nRestoring modified files..."
	# Find the latest Nodes.pm file using the find command
	local latest_nodes_pm=$(find "$BACKUP_DIR" -name "Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_nodes_pm" ]; then
		# Remove the latest Nodes.pm file
		cp "$latest_nodes_pm" "$nodespm"
		msg "Copied latest backup to $nodespm."
	else
		warn "No Nodes.pm files found."
	fi

	# Find the latest pvemanagerlib.js file using the find command
	local latest_pvemanagerlibjs=$(find "$BACKUP_DIR" -name "pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_pvemanagerlibjs" ]; then
		# Remove the latest pvemanagerlib.js file
		cp "$latest_pvemanagerlibjs" "$pvemanagerlibjs"
		msg "Copied latest backup to \"$pvemanagerlibjs\"."
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
	esac
	shift
done

# If no arguments were provided or all arguments have been processed, print the usage message
if [[ $executed -eq 0 ]]; then
	usage
fi
