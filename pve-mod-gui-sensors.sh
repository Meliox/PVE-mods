#!/usr/bin/env bash
#
# This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display sensors information.
#

################### Configuration #############
# Known CPU sensor names. They can be full or partial but should ensure unambiguous identification.
# Should new ones be added, also update logic in configure() function.
KNOWN_CPU_SENSORS=("coretemp-isa-" "k10temp-pci-")

# Overwrite default backup location
BACKUP_DIR="/root/PVE-MOD2/Backup"

##################### DO NOT EDIT BELOW #######################
# Only to be used to debug on other systems. Save the "sensor -j" output into a json file.
# Information will be loaded for script configuration and presented in Proxmox.

# DEV NOTE: lm-sensors version >3.6.0 breakes properly formatted JSON output using 'sensors -j'. This implements a workaround using uses a python3 for formatting

DEBUG_REMOTE=false
DEBUG_JSON_FILE="/tmp/sensordata.json"
DEBUG_UPS_FILE="/tmp/upsc.txt"

# This script's working directory
SCRIPT_CWD="$(dirname "$(readlink -f "$0")")"

# Debug location
JSON_EXPORT_DIRECTORY="$SCRIPT_CWD"
JSON_EXPORT_FILENAME="sensorsdata.json"

# File paths
PVE_MANAGER_LIB_JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
PVE_MOD_JS_SOURCE_FILE="$SCRIPT_CWD/PveMod_PveNodeStatusView.js"
PVE_MOD_JS_TARGET_FILE="/usr/share/pve-manager/js/PveMod_PveNodeStatusView.js"
NODES_PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"
PVE_SENSOR_INFO_MOD_FILE="/usr/share/perl5/PVE/API2/PveMod_SensorInfo.pm"
PVE_SENSOR_INFO_SOURCE_FILE="$SCRIPT_CWD/PveMod_SensorInfo.pm"

#region message tools
# Section header (bold)
function msgb() {
    local message="$1"
    echo -e "\e[1m${message}\e[0m"
}

# Info (green)
function info() {
    local message="$1"
    echo -e "\e[0;32m[info] ${message}\e[0m"
}

# Warning (yellow)
function warn() {
    local message="$1"
    echo -e "\e[0;33m[warning] ${message}\e[0m"
}

# Error (red)
function err() {
    local message="$1"
    echo -e "\e[0;31m[error] ${message}\e[0m"
    exit 1
}

# Prompts (cyan or bold)
function ask() {
    local prompt="$1"
    local response
    read -p $'\n\e[1;36m'"${prompt}:"$'\e[0m ' response
    echo "$response"
}
#endregion message tools

# Function to display usage information
function usage {
	msgb "\nUsage:\n$0 [install | uninstall | save-sensors-data]\n"
	exit 1
}

# System checks
function check_root_privileges() {
	[[ $EUID -eq 0 ]] || err "This script must be run as root. Please run it with 'sudo $0'."
	info "Root privileges verified."
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
				msgb "Decided to not install lm-sensors. The mod cannot run without it. Exiting..."
				err "lm-sensors is required. Exiting..."
				;;
			*)
				# If the user enters an invalid input, print an error message and exit the script with a non-zero status code
				err "Invalid input. Exiting..."
				;;
		esac
	fi

	# Check if lm-sensors is installed correctly and exit if not
	if (! command -v sensors &>/dev/null); then
		err "lm-sensors installation failed or 'sensors' command is not available. Please install lm-sensors manually and re-run the script."
	fi
}

# Main configuration function to detect sensors and set up parameters
function configure {
    SENSORS_DETECTED=false
    local sensorsOutput
	local sanitisedSensorsOutput
	local upsOutput
	local modelName
	local upsConnection

	install_packages

	#### Collect sensor data ####
	#region sensors collection
	if [ "$DEBUG_REMOTE" = true ]; then
		warn "Remote debugging is used. Sensor readings from dump file $DEBUG_JSON_FILE will be used."
		warn "Remote debugging is used. UPS readings from dump file $DEBUG_UPS_FILE will be used."
		sensorsOutput=$(cat "$DEBUG_JSON_FILE")
	else
		sensorsOutput=$(sensors -j 2>/dev/null)
	fi

	# Apply lm-sensors sanitization
	sanitisedSensorsOutput=$(sanitize_sensors_output "$sensorsOutput")

    if [ $? -ne 0 ]; then
        err "Sensor output error.\n\nCommand output:\n${sanitisedSensorsOutput}\n\nExiting..."
    fi
	#endregion sensors collection

	#### CPU ####
	#region CPU setup
	msgb "\n=== Detecting CPU temperature sensors ==="
	ENABLE_CPU=false
	local cpuList=""
	local cpuCount=0

	# Find all CPU sensors that match known patterns
	for pattern in "${KNOWN_CPU_SENSORS[@]}"; do
		found_sensors=$(echo "$sanitisedSensorsOutput" | grep -o "\"${pattern}[^\"]*\"" | sed 's/"//g')
		if [ -n "$found_sensors" ]; then
			while read -r sensor; do
				if [ -n "$sensor" ]; then
					cpuCount=$((cpuCount + 1))
					if [ -z "$cpuList" ]; then
						cpuList="$sensor"
					else
						cpuList="$cpuList,$sensor"
					fi
					ENABLE_CPU=true
				fi
			done <<< "$found_sensors"
		fi
	done

	if [ "$ENABLE_CPU" = true ]; then
		info "Detected CPU sensors ($cpuCount): $cpuList"
		SENSORS_DETECTED=true
		while true; do
			local choice=$(ask "Display temperatures for all cores [C] or average per CPU [a] (some newer AMD variants support per die)? (C/a)")
			case "$choice" in
				[cC]|"")
					CPU_TEMP_TARGET="Core"
					info "Temperatures will be displayed for all cores."
					break
					;;
				[aA])
					CPU_TEMP_TARGET="Package"
					info "An average temperature will be displayed per CPU."
					break
					;;
				*)
					warn "Invalid input, please choose C or a."
					;;
			esac
		done
	else
		warn "No CPU temperature sensors found."
	fi
	#endregion cpu setup
	
	#### Graphics ####
	#region Graphics setup
	msgb "\n=== Detecting Graphics information ==="

	#region intel GPU setup
	# Check for Intel GPU - ensure intel_gpu_top is installed
	if command -v intel_gpu_top &>/dev/null; then
		# detect all intel cards using intel_gpu_top -L. Show them line by line
		local intelCards
		
		# Get the output from intel_gpu_top -L, skip empty lines
		intelCards=$(intel_gpu_top -L 2>/dev/null | grep -E '^card[0-9]+' || true)
		
		if [[ -n "$intelCards" ]]; then
			local cardCount=$(echo "$intelCards" | wc -l)
			echo "Intel GPU(s) detected ($cardCount):"
			echo "$intelCards" | while IFS= read -r line; do
				# Extract card name, GPU model, and PCI info
				if [[ $line =~ ^(card[0-9]+)[[:space:]]+(.+)[[:space:]]+pci:(.+)$ ]]; then
					local cardName="${BASH_REMATCH[1]}"
					local gpuModel="${BASH_REMATCH[2]}"
					local pciInfo="${BASH_REMATCH[3]}"
					
					echo "  - Card: $cardName"
					echo "    Model: $gpuModel"
					echo "    PCI: $pciInfo"
				else
					# Fallback: just show the line as-is
					echo "  $line"
				fi
			done
			ENABLE_INTEL_GPU_INFO=true
			ENABLE_GPU_INFO=true
		else
			warn "No Intel GPUs detected by intel_gpu_top."
			ENABLE_INTEL_GPU_INFO=false
		fi
	else
		warn "intel_gpu_top command not found. Skipping Intel GPU information detection."
		ENABLE_INTEL_GPU_INFO=false
	fi
	#endregion intel GPU setup

	#region NVIDIA GPU setup
	# Check for NVIDIA GPU - ensure nvidia-smi is installed
	if command -v nvidia-smi &>/dev/null; then
		# detect all NVIDIA cards using nvidia-smi -L
		local nvidiaCards
		
		# Get the output from nvidia-smi -L (lists GPUs)
		nvidiaCards=$(nvidia-smi -L 2>/dev/null || true)
		
		if [[ -n "$nvidiaCards" ]]; then
			local cardCount=$(echo "$nvidiaCards" | wc -l)
			echo "NVIDIA GPU(s) detected ($cardCount):"
			echo "$nvidiaCards" | while IFS= read -r line; do
				# Expected format: GPU 0: NVIDIA GeForce RTX 3080 (UUID: GPU-xxxxx)
				if [[ $line =~ ^GPU\ ([0-9]+):\ (.+)\ \(UUID:\ (.+)\)$ ]]; then
					local gpuIndex="${BASH_REMATCH[1]}"
					local gpuModel="${BASH_REMATCH[2]}"
					local gpuUUID="${BASH_REMATCH[3]}"
					
					echo "  - GPU $gpuIndex"
					echo "    Model: $gpuModel"
					echo "    UUID: $gpuUUID"
				else
					# Fallback: just show the line as-is
					echo "  $line"
				fi
			done
			ENABLE_NVIDIA_GPU_INFO=true
			ENABLE_GPU_INFO=true
		else
			warn "No NVIDIA GPUs detected by nvidia-smi."
			ENABLE_NVIDIA_GPU_INFO=false
		fi
	else
		warn "nvidia-smi command not found. Skipping NVIDIA GPU information detection."
		ENABLE_NVIDIA_GPU_INFO=false
	fi
	#endregion NVIDIA GPU setup

	#region AMD GPU setup
	# not implemented yet
	#endregion AMD GPU setup

	#endregion Graphics setup

	#### RAM ####
	#region ram setup
	local ramList ramCount
	msgb "\n=== Detecting RAM temperature sensors ==="
	ramList=$(echo "$sanitisedSensorsOutput" | grep -o '"SODIMM[^"]*"' | sed 's/"//g' | paste -sd, -)
	ramCount=$(grep -c '"SODIMM[^"]*"' <<<"$sanitisedSensorsOutput")

	if [ "$ramCount" -gt 0 ]; then
		info "Detected RAM sensors ($ramCount): $ramList"
		ENABLE_RAM_TEMP=true
		SENSORS_DETECTED=true
	else
		warn "No RAM temperature sensors found."
		ENABLE_RAM_TEMP=false
	fi
	#endregion ram setup

    #### HDD/SSD ####
	#region hdd setup
    msgb "\n=== Detecting HDD/SSD temperature sensors ==="
    local hddList=($(echo "$sanitisedSensorsOutput" | grep -o '"drivetemp-scsi[^"]*"' | sed 's/"//g'))
    if [ ${#hddList[@]} -gt 0 ]; then
        info "Detected HDD/SSD sensors (${#hddList[@]}): $(IFS=,; echo "${hddList[*]}")"
        ENABLE_HDD_TEMP=true
        SENSORS_DETECTED=true
    else
        warn "No HDD/SSD temperature sensors found."
        ENABLE_HDD_TEMP=false
    fi
	#endregion hdd setup

    #### NVMe ####
	#region nvme setup
    msgb "\n=== Detecting NVMe temperature sensors ==="
    local nvmeList=($(echo "$sanitisedSensorsOutput" | grep -o '"nvme[^"]*"' | sed 's/"//g'))
    if [ ${#nvmeList[@]} -gt 0 ]; then
        info "Detected NVMe sensors (${#nvmeList[@]}): $(IFS=,; echo "${nvmeList[*]}")"
        ENABLE_NVME_TEMP=true
        SENSORS_DETECTED=true
    else
        warn "No NVMe temperature sensors found."
        ENABLE_NVME_TEMP=false
    fi
	#endregion nvme setup

	#### Fans ####
	#region fan setup
	msgb "\n=== Detecting fan speed sensors ==="

	local fanList=""
	local fanCount=0

	# Find all fan names that have fan*_input entries
	fanList=$(echo "$sanitisedSensorsOutput" | grep -B2 '"fan[0-9]\+_input"' | grep '".*": {' | sed 's/.*"\([^"]*\)": {.*/\1/' | sort -u | paste -sd, -)
	fanCount=$(grep -c 'fan[0-9]\+_input' <<<"$sanitisedSensorsOutput")

	if [ "$fanCount" -gt 0 ]; then
		info "Detected fan speed sensors ($fanCount): $fanList"
		ENABLE_FAN_SPEED=true
		SENSORS_DETECTED=true

		local choice
		choice=$(ask "Display fans reporting zero speed? (Y/n)")
		case "$choice" in
			[yY]|"")
				DISPLAY_ZERO_SPEED_FANS=true
				info "Zero-speed fans will be displayed."
				;;
			[nN])
				DISPLAY_ZERO_SPEED_FANS=false
				info "Only active fans will be displayed."
				;;
			*)
				warn "Invalid input. Defaulting to show zero-speed fans."
				DISPLAY_ZERO_SPEED_FANS=true
				;;
		esac
	else
		warn "No fan speed sensors found."
		ENABLE_FAN_SPEED=false
	fi
	#endregion fan setup

    #### Temperature Units ####
	#region temp unit setup
	msgb "\n=== Display temperature ==="
    if [ "$SENSORS_DETECTED" = true ]; then
        local unit=$(ask "Display temperatures in Celsius [C] or Fahrenheit [f]? (C/f)")
        case "$unit" in
            [cC]|"")
                TEMP_UNIT="C"
                info "Using Celsius."
                ;;
            [fF])
                TEMP_UNIT="F"
                info "Using Fahrenheit."
                ;;
            *)
                warn "Invalid selection. Defaulting to Celsius."
                TEMP_UNIT="C"
                ;;
        esac
    fi
	#endregion temp unit setup

    #### UPS ####
	#region ups setup
    local choiceUPS=$(ask "Enable UPS information? (y/N)")
    case "$choiceUPS" in
        [yY])
            if [ "$DEBUG_REMOTE" = true ]; then
                upsOutput=$(cat "$DEBUG_UPS_FILE")
                info "Remote debugging: UPS readings from $DEBUG_UPS_FILE"
                upsConnection="DEBUG_UPS"
            else
                upsConnection=$(ask "Enter UPS connection (e.g., upsname[@hostname[:port]])")
                if ! command -v upsc &>/dev/null; then
                    err "The 'upsc' command is not available. Install 'nut-client'."
                fi
                upsOutput=$(upsc "$upsConnection" 2>&1)
            fi

            if echo "$upsOutput" | grep -q "device.model:"; then
                modelName=$(echo "$upsOutput" | grep "device.model:" | cut -d':' -f2- | xargs)
                ENABLE_UPS=true
                info "Connected to UPS model: $modelName at $upsConnection."
            else
                warn "Failed to connect to UPS at '$upsConnection'."
                ENABLE_UPS=false
            fi
            ;;
        [nN]|"")
            ENABLE_UPS=false
            info "UPS information will not be displayed."
            ;;
        *)
            warn "Invalid selection. UPS info will not be displayed."
            ENABLE_UPS=false
            ;;
    esac
	#endregion ups setup

    #### System Info ####
	#region system info setup
    msgb "\n=== Detecting System Information ==="
    for i in 1 2; do
        echo "type ${i})"
        dmidecode -t "$i" | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print $1": "$2}'
    done
    local choiceSysInfo=$(ask "Enable system information? (1/2/n)")
    case "$choiceSysInfo" in
        [1]|"")
            ENABLE_SYSTEM_INFO=true
            SYSTEM_INFO_TYPE=1
            info "System information will be displayed."
            ;;
        [2])
            ENABLE_SYSTEM_INFO=true
            SYSTEM_INFO_TYPE=2
            info "Motherboard information will be displayed."
            ;;
        [nN])
            ENABLE_SYSTEM_INFO=false
            info "System information will NOT be displayed."
            ;;
        *)
            warn "Invalid selection. Defaulting to system information."
            ENABLE_SYSTEM_INFO=true
            SYSTEM_INFO_TYPE=1
            ;;
    esac
	#endregion system info setup

    #### Final Check ####
	#region final check
    if [ "$SENSORS_DETECTED" = false ] && [ "$ENABLE_UPS" = false ] && [ "$ENABLE_SYSTEM_INFO" = false ]; then
        err "No sensors detected, UPS or system info enabled. Exiting."
    fi
	#endregion final check
}


# Function to install the modification
function install_mod {
    msgb "\n=== Preparing mod installation ==="
    check_root_privileges
    check_mod_installation
    configure
    perform_backup

    #### Insert information retrieval code ####
    msgb "\n=== Installing sensor info module ==="
	install_sensor_monitor_module
	insert_sensor_monitor_into_pve
	insert_system_info_into_pve

    #### Install UI modification module ####
    msgb "\n=== Installing UI modification module ==="
    install_node_status_view_module

    msgb "\n=== Finalizing installation ==="

    restart_proxy
    info "Installation completed."
    ask "Clear the browser cache to ensure all changes are visualized. (any key to continue)"
}

# Sanitize sensors output to handle common lm-sensors parsing issues
sanitize_sensors_output() {
    local input="$1"

    # Pipe the text into Perl:
    #   -0777  → "slurp mode": read the entire stream as one string so
    #            regexes can match across line breaks.
    #   -pe    → loop over input, applying the script (-e) and printing.
	# Apply python3 json.tool for proper formatting and validation
    echo "$input" | perl -0777 -pe '
        # Replace ERROR lines with placeholder values
        s/ERROR:.+\s(\w+):\s(.+)/"$1": 0.000,/g;
        s/ERROR:.+\s(\w+)!/"$1": 0.000,/g;

        # Remove trailing commas before closing braces
        s/,\s*(\})/$1/g;

        # Replace NaN values with null
        s/\bNaN\b/null/g;

        # Fix duplicate SODIMM keys - handle both pretty and one-line JSON  
        s/"SODIMM"\s*:\s*\{\s*"temp(\d+)_input"/"SODIMM $1": {\n  "temp$1_input"/g;

        # Fix duplicate fan keys - handle both pretty and one-line JSON
        s/"([^"]*Fan[^"]*)"\s*:\s*\{\s*"fan(\d+)_input"/"$1 $2": {\n  "fan$2_input"/g;
    ' | python3 -m json.tool 2>/dev/null || echo "$input"
}

#region Sensor Monitor Module Installation
# Install and configure the Sensor Monitor Perl module
install_sensor_monitor_module() {
	local intel_enabled nvidia_enabled ups_enabled sensors_mode
    # Check if source file exists
    if [[ ! -f "$PVE_SENSOR_INFO_SOURCE_FILE" ]]; then
        err "Source file not found: $PVE_SENSOR_INFO_SOURCE_FILE"
    fi

    # Copy the module file
    cp "$PVE_SENSOR_INFO_SOURCE_FILE" "$PVE_SENSOR_INFO_MOD_FILE" || err "Failed to copy $PVE_SENSOR_INFO_SOURCE_FILE to $PVE_SENSOR_INFO_MOD_FILE"
    info "Copied Sensor Monitor module to $PVE_SENSOR_INFO_MOD_FILE"

    # Convert boolean flags to Perl format (1 or 0)
    intel_enabled=$([[ "$ENABLE_INTEL_GPU_INFO" = true ]] && echo 1 || echo 0)
    nvidia_enabled=$([[ "$ENABLE_NVIDIA_GPU_INFO" = true ]] && echo 1 || echo 0)
    ups_enabled=$([[ "$ENABLE_UPS" = true ]] && echo 1 || echo 0)
    sensors_mode=$([[ "$DEBUG_REMOTE" = true ]] && echo 1 || echo 0)
    
    # Determine UPS device name
    local ups_device="${upsConnection:-ups@localhost}"
    
    # Update configuration in the installed module
    sed -i "
        # Update GPU configuration
        /intel_enabled =>/ s/=> [01],/=> $intel_enabled,/
		/nvidia_enabled =>/ s/=> [01],/=> $nvidia_enabled,/
        
        # Update UPS configuration
        /enabled =>/ {
            /ups => {/,/},/ {
                /enabled =>/ s/=> [01],/=> $ups_enabled,/
            }
        }
        /device_name =>/ s|=> '[^']*',|=> '$ups_device',|
    " "$PVE_SENSOR_INFO_MOD_FILE"

    if [[ $? -eq 0 ]]; then
        info "Sensor Monitor module configured successfully."
    else
        warn "Failed to configure Sensor Monitor module settings."
    fi
}
#endregion Sensor Monitor Module Installation

#region node info insertion
# Main insertion routine
insert_sensor_monitor_into_pve() {
	#region PveSensorInfoMod heredoc
	sed -i '/my \$dinfo = df('\''\/'\'', 1);/i\
		# Collect sensor data from PveMod_SensorInfo\
		# Bad practice to add use here, but cleaner implementation would require several extensive modifications.\
		use PVE::API2::PVEMod_SensorInfo;\
		$res->{PveMod_JsonSensorInfo} = PVE::API2::PVEMod_SensorInfo::get_sensors_info();\
		$res->{PveMod_graphicsInfo} = PVE::API2::PVEMod_SensorInfo::get_pve_mod_version();\
		$res->{PveMod_upsInfo} = PVE::API2::PVEMod_SensorInfo::get_ups_info();\
	' "$NODES_PM_FILE"
	#endregion PveSensorInfoMod heredoc
    info "Sensor data retriever added to \"$NODES_PM_FILE\"."
}

# Collect system information
insert_system_info_into_pve() {
    local output_file="$1"
    local systemInfoCmd

	if [[ $ENABLE_SYSTEM_INFO == false ]]; then
		return
	fi

    systemInfoCmd=$(dmidecode -t "${SYSTEM_INFO_TYPE}" \
        | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print $1": "$2}' \
        | awk '{$1=$1};1' \
        | sed 's/$/ |/' \
        | paste -sd " " - \
        | sed 's/ |$//')
	#region system info heredoc
	sed -i "/my \$dinfo = df('\/', 1);/i\\
		# Add system information to response\\
		\$res->{pveMod_sensorInfo_systemInfo} = \"$(echo "$systemInfoCmd")\";\\
" "$NODES_PM_FILE"
	#endregion system info heredoc
    info "System information retriever added to \"$output_file\"."
}
#endregion node info insertion

#region UI Module Installation
# Install the UI modification module
install_node_status_view_module() {
    # Check if source file exists
    if [[ ! -f "$PVE_MOD_JS_SOURCE_FILE" ]]; then
        err "Source file not found: $PVE_MOD_JS_SOURCE_FILE"
    fi

    # Copy the JavaScript module to PVE manager directory
    cp "$PVE_MOD_JS_SOURCE_FILE" "$PVE_MOD_JS_TARGET_FILE" || err "Failed to copy $PVE_MOD_JS_SOURCE_FILE to $PVE_MOD_JS_TARGET_FILE"
    info "Copied UI module to $PVE_MOD_JS_TARGET_FILE"

    # Comment out the original PVE.node.StatusView definition in pvemanagerlib.js
    # This allows our custom module to provide the new definition
    if grep -q "^Ext.define('PVE.node.StatusView'," "$PVE_MANAGER_LIB_JS_FILE" 2>/dev/null; then
        # Find the start of the definition and comment it out until the matching closing brace
        sed -i "/^Ext\.define('PVE\.node\.StatusView',/,/^});/s|^|// |" "$PVE_MANAGER_LIB_JS_FILE"
        info "Commented out original StatusView definition in pvemanagerlib.js"
    else
        warn "Original StatusView definition not found in expected format in pvemanagerlib.js"
    fi

    # Add a dynamic script loader to load our custom module
    # Insert before the commented-out Ext.define to load it
    if ! grep -q "PveMod_PveNodeStatusView.js" "$PVE_MANAGER_LIB_JS_FILE" 2>/dev/null; then
        # Use ExtJS Loader to dynamically load our custom module
        sed -i "/^\/\/ Ext\.define('PVE\.node\.StatusView',/i\\
// Load custom PVE.node.StatusView from external module\\
Ext.Loader.loadScript({\\
    url: '/pve2/js/PveMod_PveNodeStatusView.js',\\
    onLoad: function() { },\\
    onError: function() { console.error('Failed to load PveMod_PveNodeStatusView.js'); }\\
});\\
" "$PVE_MANAGER_LIB_JS_FILE"
        info "Added dynamic loader for custom UI module in pvemanagerlib.js"
    else
        info "Custom UI module loader already present in pvemanagerlib.js"
    fi
}
#endregion UI Module Installation

# Function to uninstall the modification
function uninstall_mod {
	msgb "=== Uninstalling Mod ==="

	check_root_privileges

	if [[ -z $(grep -e "\$res->{PveMod_SensorInfo_JSON}" "$NODES_PM_FILE") ]] && [[ -z $(grep -e "\$res->{systemInfo}" "$NODES_PM_FILE") ]]; then
		err "Mod is not installed."
	fi

	set_backup_directory
	info "Restoring modified files..."

	# Find the latest Nodes.pm file using the find command
	local latest_nodes_pm=$(find "$BACKUP_DIR" -name "Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_nodes_pm" ]; then
		# Restore the latest Nodes.pm file
		msgb "Restoring latest Nodes.pm from backup: $latest_nodes_pm to \"$NODES_PM_FILE\"."
		cp "$latest_nodes_pm" "$NODES_PM_FILE"
		info "Restored Nodes.pm successfully."
	else
		warn "No Nodes.pm backup files found."
	fi

	# Restore original pvemanagerlib.js (uncomment the StatusView definition and remove loader)
	local latest_pvemanagerlibjs=$(find "$BACKUP_DIR" -name "pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_pvemanagerlibjs" ]; then
		# Restore the latest pvemanagerlib.js file
		msgb "Restoring latest pvemanagerlib.js from backup: $latest_pvemanagerlibjs to \"$PVE_MANAGER_LIB_JS_FILE\"."
		cp "$latest_pvemanagerlibjs" "$PVE_MANAGER_LIB_JS_FILE"
		info "Restored pvemanagerlib.js successfully."
	else
		warn "No pvemanagerlib.js backup files found."
	fi

	# Remove UI module files
	if [ -f "$PVE_MOD_JS_TARGET_FILE" ]; then
		msgb "Removing UI module: $PVE_MOD_JS_TARGET_FILE"
		rm "$PVE_MOD_JS_TARGET_FILE"
		info "Removed UI module successfully."
	else
		warn "UI module file not found: $PVE_MOD_JS_TARGET_FILE"
	fi

	# Remove Sensor Info Perl module
	local latest_sensor_info_pm=$(find "$BACKUP_DIR" -name "PveMod_SensorInfo.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_sensor_info_pm" ]; then
		# Restore the latest PveMod_SensorInfo.pm file (if there's a backup)
		msgb "Restoring latest PveMod_SensorInfo.pm from backup: $latest_sensor_info_pm to \"$PVE_SENSOR_INFO_MOD_FILE\"."
		cp "$latest_sensor_info_pm" "$PVE_SENSOR_INFO_MOD_FILE"
		info "Restored PveMod_SensorInfo.pm successfully."
	elif [ -f "$PVE_SENSOR_INFO_MOD_FILE" ]; then
		# No backup found but file exists, remove it
		msgb "No PveMod_SensorInfo.pm backup found. Removing installed module: $PVE_SENSOR_INFO_MOD_FILE"
		rm "$PVE_SENSOR_INFO_MOD_FILE"
		info "Removed PveMod_SensorInfo.pm successfully."
	else
		warn "No PveMod_SensorInfo.pm backup files found and module not installed."
	fi

	if [ -n "$latest_nodes_pm" ] || [ -n "$latest_pvemanagerlibjs" ] || [ -f "$PVE_MOD_JS_TARGET_FILE" ] || [ -n "$latest_sensor_info_pm" ] || [ -f "$PVE_SENSOR_INFO_MOD_FILE" ]; then
		# At least one file was modified, restart the proxy
		restart_proxy
	fi

	ask "Clear the browser cache to ensure all changes are visualized. (any key to continue)"
}

# Function to check if the modification is installed
check_mod_installation() {
    if [[ -n $(grep -F 'use PVE::API2::PveMod_SensorInfo' "$NODES_PM_FILE") ]] || \
       [[ -n $(grep -F 'use PVE::API2::PVEMod_SensorInfo' "$NODES_PM_FILE") ]] || \
       [[ -n $(grep -F '$res->{sensorsJSONOutput}' "$NODES_PM_FILE") ]] || \
       [[ -n $(grep -F '$res->{systemInfo}' "$NODES_PM_FILE") ]] || \
       [[ -f "$PVE_MOD_JS_TARGET_FILE" ]]; then
        err "Mod is already installed. Uninstall existing before installing."
    fi
}

function restart_proxy {
	# Restart pveproxy
	info "Restarting PVE proxy..."
	systemctl restart pveproxy
}

function save_sensors_data {
	msgb "=== Saving Sensors Data ==="

	# Check if JSON_EXPORT_DIRECTORY exists and is writable
	if [[ ! -d "$JSON_EXPORT_DIRECTORY" || ! -w "$JSON_EXPORT_DIRECTORY" ]]; then
		err "Directory $JSON_EXPORT_DIRECTORY does not exist or is not writable. No file could be saved."
		return
	fi


	# Check if command exists
	if (command -v sensors &>/dev/null); then
		# Save sensors output
		local debug_save_filename="sensorsdata.json"
		local filepath="${JSON_EXPORT_DIRECTORY}/${debug_save_filename}"
		msgb "Sensors data will be saved in $filepath"

		# Prompt user for confirmation
		local choiceContinue=$(ask "Do you wish to continue? (Y/n)")
		case "$choiceContinue" in
			[yY]|"")
				echo "lm-sensors raw output:" >"$filepath"
				sensorsOutput=$(sensors -j 2>/dev/null)
				echo "$sensorsOutput" >>"$filepath"
				echo -e "\n\nSanitised lm-sensors output:" >>"$filepath"
				# Apply lm-sensors sanitization
				sanitisedSensorsOutput=$(sanitize_sensors_output "$sensorsOutput")
				echo "$sanitisedSensorsOutput" >>"$filepath"
				info "Sensors data saved in $filepath."
				;;
			*)
				warn "Operation cancelled by user."
				;;
		esac
	else
		err "Sensors is not installed. No file could be saved."
	fi
	echo
}

function set_backup_directory {
	# Check if the BACKUP_DIR variable is set, if not, use the default backup
	if [[ -z "$BACKUP_DIR" ]]; then
		# If not set, use the default backup directory, which is based on the home directory and PVE-MODS
		BACKUP_DIR="$HOME/PVE-MODS"
		info "Using default backup directory: $BACKUP_DIR"
	else
		# If set, ensure it is a valid directory
		if [[ ! -d "$BACKUP_DIR" ]]; then
			err "The specified backup directory does not exist: $BACKUP_DIR"
		fi
		info "Using custom backup directory: $BACKUP_DIR"
	fi
}

function create_backup_directory {
	set_backup_directory

	# Create the backup directory if it does not exist
	if [[ ! -d "$BACKUP_DIR" ]]; then
		mkdir -p "$BACKUP_DIR" 2>/dev/null || {
			err "Failed to create backup directory: $BACKUP_DIR. Please check permissions."
		}
		info "Created backup directory: $BACKUP_DIR"
	else
		info "Backup directory already exists: $BACKUP_DIR"
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
    
    info "Created backup: $backup_file"
}

function perform_backup {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
	msgb "\n=== Creating backups of modified files ==="

    create_backup_directory
    create_file_backup "$NODES_PM_FILE" "$timestamp"
    create_file_backup "$PVE_MANAGER_LIB_JS_FILE" "$timestamp"
    
    # Backup Sensor Info module if it exists
    if [[ -f "$PVE_SENSOR_INFO_MOD_FILE" ]]; then
        create_file_backup "$PVE_SENSOR_INFO_MOD_FILE" "$timestamp"
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
			;;
		uninstall)
			executed=$(($executed + 1))
			msgb "\nUninstalling the Proxmox VE sensors display mod..."
			uninstall_mod
			;;
		save-sensors-data)
			executed=$(($executed + 1))
			msgb "\nSaving current sensor readings in a file for debugging..."
			save_sensors_data
			;;
	esac
	shift
done

# If no arguments were provided or all arguments have been processed, print the usage message
if [[ $executed -eq 0 ]]; then
	usage
fi