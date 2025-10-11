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
NODES_PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"

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

function configure {
    SENSORS_DETECTED=false
    local sensorsOutput
	local sanitisedSensorsOutput
	local upsOutput
	local modelName
	local upsConnection

	install_packages

	#### Collect lm-sensors output ####
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
	#region cpu setup
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

	#### RAM ####
	#region ram setup
	msgb "\n=== Detecting RAM temperature sensors ==="
	local ramList=$(echo "$sanitisedSensorsOutput" | grep -o '"SODIMM[^"]*"' | sed 's/"//g' | paste -sd, -)
	local ramCount=$(grep -c '"SODIMM[^"]*"' <<<"$sanitisedSensorsOutput")

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
    msgb "\n=== Inserting information retrieval code ==="
    insert_node_info

    #### Temperature helper parameters ####
    msgb "\n=== Creating temperature conversion helper ==="
    HELPERCTORPARAMS=$([[ "$TEMP_UNIT" = "F" ]] && \
        echo '{srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: PVE.mod.TempHelper.FAHRENHEIT}' || \
        echo '{srcUnit: PVE.mod.TempHelper.CELSIUS, dstUnit: PVE.mod.TempHelper.CELSIUS}')
    info "Temperature helper configured for $TEMP_UNIT."

    #### Expand StatusView space ####
    expand_statusview_space

    #### Insert temperature helper ####
    generate_and_insert_temp_helper

    #### Generate and insert widgets ####
    msgb "\n=== Making visual adjustments ==="

    generate_and_insert_widget "$ENABLE_SYSTEM_INFO" "generate_system_info" "system_info"
    generate_and_insert_widget "$ENABLE_UPS" "generate_ups_widget" "ups"
    generate_and_insert_widget "$ENABLE_HDD_TEMP" "generate_hdd_widget" "hdd"
    generate_and_insert_widget "$ENABLE_NVME_TEMP" "generate_nvme_widget" "nvme"

    if [[ "$ENABLE_HDD_TEMP" = true || "$ENABLE_NVME_TEMP" = true ]]; then
        generate_drive_header
        info "Drive headers added."
    fi

    generate_and_insert_widget "$ENABLE_FAN_SPEED" "generate_fan_widget" "fan"
    generate_and_insert_widget "$ENABLE_RAM_TEMP" "generate_ram_widget" "ram"
    generate_and_insert_widget "$ENABLE_CPU" "generate_cpu_widget" "cpu"

    #### Visual separation ####
    add_visual_separator
    info "Added visual separator for modified items."

    #### Node summary ####
    setup_node_summary_container
    info "Node summary box moved into its own container."

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

#region node info insertion
# Main insertion routine
insert_node_info() {
    local output_file="$NODES_PM_FILE"

    collect_sensors_output "$output_file"

    if [[ $ENABLE_UPS == true ]]; then
        collect_ups_output "$output_file"
    fi

    if [[ $ENABLE_SYSTEM_INFO == true ]]; then
        collect_system_info "$output_file"
    fi
}

# Collect lm-sensors data
collect_sensors_output() {
    local output_file="$1"
    local sensorsCmd

    if [[ $DEBUG_REMOTE == true ]]; then
        sensorsCmd="cat \"$DEBUG_JSON_FILE\""
    else
        # Note: sensors -f (Fahrenheit) breaks fan speeds
        sensorsCmd="sensors -j 2>/dev/null"
    fi

	# Remember to reflect this in sanitize_sensors_output() 
	#region sensors heredoc
	sed -i '/my \$dinfo = df('\''\/'\'', 1);/i\
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
        # Fix duplicate SODIMM keys by appending temperature sensor number with a space - handle both pretty and one-line JSON\
		# Example: "SODIMM":{"temp3_input":34.0} becomes "SODIMM 3":{"temp3_input":34.0}\
        $res->{sensorsOutput} =~ s/"SODIMM"\\s*:\\s*\\{\\s*"temp(\\d+)_input"/"SODIMM $1": {\\n  "temp$1_input"/g;\
		\
		# Fix duplicate fans keys by appending fan number with a space - handle both pretty and one-line JSON\
		# Example: "Processor Fan":{"fan2_input":1000,...} → "Processor Fan 2":{"fan2_input":1000,...}\
		$res->{sensorsOutput} =~ s/"([^"]+)"\\s*:\\s*\{\\s*"fan(\\d+)_input"/"$1 $2": {\\n  "fan$2_input"/g;\
		\
		# Format JSON output properly (workaround for lm-sensors >3.6.0 issues)\
		$res->{sensorsOutput} =~ /^(.*)$/s;\
		$res->{sensorsOutput} = `echo \\Q$1\\E | python3 -m json.tool 2>/dev/null || echo \\Q$1\E`;\
	' "$NODES_PM_FILE"
	#endregion sensors heredoc
    info "Sensors' retriever added to \"$output_file\"."
}

# Collect UPS data
collect_ups_output() {
    local output_file="$1"
    local ups_cmd

    if [[ $DEBUG_REMOTE == true ]]; then
        ups_cmd="cat \"$DEBUG_UPS_FILE\""
    else
        ups_cmd="upsc \"$upsConnection\" 2>/dev/null"
    fi

    # region ups heredoc
    sed -i "/my \$dinfo = df('\/', 1);/i\\
		# Collect UPS status information\\
		sub get_upsc {\\
			my \$cmd = '$ups_cmd';\\
			my \$output = \`\\\$cmd\`;\\
			return \$output;\\
		}\\
		\$res->{upsc} = get_upsc();\\
" "$NODES_PM_FILE"
    # endregion ups heredoc

    info "UPS retriever added to \"$output_file\"."
}


# Collect system information
collect_system_info() {
    local output_file="$1"
    local systemInfoCmd

    systemInfoCmd=$(dmidecode -t "${SYSTEM_INFO_TYPE}" \
        | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print $1": "$2}' \
        | awk '{$1=$1};1' \
        | sed 's/$/ |/' \
        | paste -sd " " - \
        | sed 's/ |$//')
	#region system info heredoc
	sed -i "/my \$dinfo = df('\/', 1);/i\\
		# Add system information to response\\
		\$res->{systemInfo} = \"$(echo "$systemInfoCmd")\";\\
" "$NODES_PM_FILE"
	#endregion system info heredoc
    info "System information retriever added to \"$output_file\"."
}
#endregion node info insertion

#region widget generation functions
# Helper function to insert widget after thermal items
insert_widget_after_thermal() {
	local widget_file="$1"
	sed -i "/^Ext.define('PVE.node.StatusView',/ {
		:a
		/items:/!{N;ba;}
		:b
		/'cpus.*},/!{N;bb;}
		r $widget_file
	}" "$PVE_MANAGER_LIB_JS_FILE"
}

# Helper function to generate widget and insert it
generate_and_insert_widget() {
	local enable_flag="$1"
	local generator_func="$2"
	local widget_name="$3"
	
	if [ "$enable_flag" = true ]; then
		local temp_js_file="/tmp/${widget_name}_widget.js"
		"$generator_func" "$temp_js_file"
		insert_widget_after_thermal "$temp_js_file"
		rm "$temp_js_file"
		info "Inserted $widget_name widget."
	fi
}

# Function to generate drive header
generate_drive_header() {
	if [ "$ENABLE_NVME_TEMP" = true ] || [ "$ENABLE_HDD_TEMP" = true ]; then
        local temp_js_file="/tmp/drive_header.js"	
		#region drive header heredoc
		cat > "$temp_js_file" <<'EOF'
		{
			xtype: 'box',
			colspan: 2,
			html: gettext('Drive(s)'),
		},
EOF
#endregion drive header heredoc  
        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to generate drive header code" >&2
            exit 1
        fi
        
        insert_widget_after_thermal "$temp_js_file"
        rm "$temp_js_file"
    fi
}

# Function to expand space and modify StatusView properties
expand_statusview_space() {
	msgb "\n=== Expanding StatusView space ==="

    # Apply multiple modifications to the StatusView definition
    sed -i "/Ext.define('PVE\.node\.StatusView'/,/\},/ {
        s/\(bodyPadding:\) '[^']*'/\1 '20 15 20 15'/
        s/height: [0-9]\+/minHeight: 360,\n\tflex: 1,\n\tcollapsible: true,\n\ttitleCollapse: true/
        s/\(tableAttrs:.*$\)/trAttrs: \{ valign: 'top' \},\n\t\1/
    }" "$PVE_MANAGER_LIB_JS_FILE"

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to expand StatusView space" >&2
        exit 1
    fi
    
    info "Expanded space in \"$PVE_MANAGER_LIB_JS_FILE\"."
}

# Function to move node summary into its own container
setup_node_summary_container() {
    # Move the node summary box into its own container
    local temp_js_file="/tmp/summary_container.js"
    #region summary container heredoc
    cat > "$temp_js_file" <<'EOF'
{
	xtype: 'container',
	itemId: 'summarycontainer',
	layout: 'column',
	minWidth: 700,
	defaults: {
		minHeight: 350,
		padding: 5,
		columnWidth: 1,
	},
	items: [
		nodeStatus,
	]
},
EOF
#endregion summary container heredoc    
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate summary container code" >&2
        exit 1
    fi
    
    # Insert the new container after finding the nodeStatus and items pattern
    sed -i "/^\s*nodeStatus: nodeStatus,/ {
        :a
        /items: \[/ !{N;ba;}
        r $temp_js_file
    }" "$PVE_MANAGER_LIB_JS_FILE"
    
    rm "$temp_js_file"
    
    # Deactivate the original box instance
    sed -i "/^\s*nodeStatus: nodeStatus,/ {
        :a
        /itemId: 'itemcontainer',/ !{N;ba;}
        n;
        :b
        /nodeStatus,/ !{N;bb;}
        s/nodeStatus/\/\/nodeStatus/
    }" "$PVE_MANAGER_LIB_JS_FILE"
    
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to deactivate original nodeStatus instance" >&2
        exit 1
    fi
}

# Function to add visual spacing separator after the last widget
add_visual_separator() {
    # Check for the presence of items in the reverse order of display
    local lastItemId=""
    
    if [ "$ENABLE_UPS" = true ]; then
        lastItemId="upsc"
    elif [ "$ENABLE_HDD_TEMP" = true ]; then
        lastItemId="thermalHdd"
    elif [ "$ENABLE_NVME_TEMP" = true ]; then
        lastItemId="thermalNvme"
    elif [ "$ENABLE_FAN_SPEED" = true ]; then
        lastItemId="speedFan"
    else
        lastItemId="thermalCpu"
    fi

    if [ -n "$lastItemId" ]; then
        local temp_js_file="/tmp/visual_separator.js"
        
		#region visual spacing heredoc
        cat > "$temp_js_file" <<'EOF'
		{
			xtype: 'box',
			colspan: 2,
			padding: '0 0 20 0',
		},
EOF
#endregion visual spacing heredoc        
        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to generate visual separator code" >&2
            exit 1
        fi
        
        # Insert after the specific lastItemId (different pattern than thermal)
        sed -i "/^Ext.define('PVE.node.StatusView',/ {
            :a;
            /^.*{.*'$lastItemId'.*},/!{N;ba;}
            r $temp_js_file
        }" "$PVE_MANAGER_LIB_JS_FILE"
        
        rm "$temp_js_file"
    fi
}

# Function to generate system info widget
generate_system_info() {
	#region system info heredoc
    cat > "$1" <<'EOF'
		{
			itemId: 'sysinfo',
			colspan: 2,
			printBar: false,
			title: gettext('System Information'),
			textField: 'systemInfo',
			renderer: function(value){
				return value;
			}
		},
EOF
	#endregion system info heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate system info code" >&2
        exit 1
    fi
}

# Function to generate and insert temperature conversion helper class
generate_and_insert_temp_helper() {
	local temp_js_file="/tmp/temp_helper.js"

	msgb "\n=== Inserting temperature helper ==="

	#region temp helper heredoc
    cat > "$temp_js_file" <<'EOF'
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
EOF
	#endregion temp helper heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate temp helper code" >&2
        exit 1
    fi

	sed -i "/^Ext.define('PVE.node.StatusView'/e cat /tmp/temp_helper.js" "$PVE_MANAGER_LIB_JS_FILE"
	rm "$temp_js_file"

	info "Temperature helper inserted successfully."
}

# Function to generate CPU widget
generate_cpu_widget() {
	#region cpu widget heredoc
	# use subshell to allow variable expansion
	(
		export CPU_ITEMS_PER_ROW
		export CPU_TEMP_TARGET
		export HELPERCTORPARAMS
		
		cat <<'EOF' | envsubst '$CPU_ITEMS_PER_ROW $CPU_TEMP_TARGET $HELPERCTORPARAMS' > "$1"
		{
			itemId: 'thermalCpu',
			colspan: 2,
			printBar: false,
			title: gettext('CPU Thermal State'),
			iconCls: 'fa fa-fw fa-thermometer-half',
			textField: 'sensorsOutput',
			renderer: function(value){
				// sensors configuration
				const cpuTempHelper = Ext.create('PVE.mod.TempHelper', $HELPERCTORPARAMS);
				// display configuration
				const itemsPerRow = $CPU_ITEMS_PER_ROW;
				// ---
				let objValue;
				try {
					objValue = JSON.parse(value) || {};
				} catch(e) {
					objValue = {};
				}
				const cpuKeysI = Object.keys(objValue).filter(item => String(item).startsWith('coretemp-isa-')).sort();
				const cpuKeysA = Object.keys(objValue).filter(item => String(item).startsWith('k10temp-pci-')).sort();
				const bINTEL = cpuKeysI.length > 0 ? true : false;
				const INTELPackagePrefix = '$CPU_TEMP_TARGET' == 'Core' ? 'Core ' : 'Package id';
				const INTELPackageCaption = '$CPU_TEMP_TARGET' == 'Core' ? 'Core' : 'Package';
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
					if (bTccd && '$CPU_TEMP_TARGET' == 'Core') {
						AMDPackagePrefix = 'Tccd';
						AMDPackageCaption = 'ccd';
					} else if (bCpuCoreTemp && '$CPU_TEMP_TARGET' == 'Package') {
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
					const itemKeys = Object.keys(items).filter(item => { 
						if ('$CPU_TEMP_TARGET' == 'Core') {
							// In Core mode: only show individual cores/CCDs, exclude overall CPU temp
							return String(item).includes(cpuItemPrefix) || String(item).startsWith('Tccd');
						} else {
							// In Package mode: show overall CPU temp and package-level readings
							return String(item).includes(cpuItemPrefix) || String(item) === 'CPU Core Temp';
						}
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
						temps.push(cpuTemps);
					}
				});
				
				let result = '';
				temps.forEach((cpuTemps, cpuIndex) => {
					const strCoreTemps = cpuTemps.map((strTemp, index, arr) => { 
						return strTemp + (index + 1 < arr.length ? (itemsPerRow > 0 && (index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); 
					})
					if(strCoreTemps.length > 0) {
						result += (cpuCount > 1 ? `CPU ${cpuIndex+1}: ` : '') + strCoreTemps.join('') + (cpuIndex < cpuCount ? '<br>' : '');
					}
				});
				
				return '<div style="text-align: left; margin-left: 28px;">' + (result.length > 0 ? result : 'N/A') + '</div>';
			}
		},
EOF
	)
	#endregion cpu widget heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate cpu widget code" >&2
        exit 1
    fi
}

# Function to generate nvme widget
generate_nvme_widget() {
	#region nvme widget heredoc
	# use subshell to allow variable expansion
	(
		export HELPERCTORPARAMS
		export NVME_ITEMS_PER_ROW
		cat <<'EOF' | envsubst '$HELPERCTORPARAMS $NVME_ITEMS_PER_ROW' > "$1"
		{
			itemId: 'thermalNvme',
			colspan: 2,
			printBar: false,
			title: gettext('NVMe Thermal State'),
			iconCls: 'fa fa-fw fa-thermometer-half',
			textField: 'sensorsOutput',
			renderer: function(value) {
				// sensors configuration
				const addressPrefix = "nvme-pci-";
				const sensorName = "Composite";
				const tempHelper = Ext.create('PVE.mod.TempHelper', $HELPERCTORPARAMS);
				// display configuration
				const itemsPerRow = $NVME_ITEMS_PER_ROW;
				// ---
				let objValue;
				try {
					objValue = JSON.parse(value) || {};
				} catch(e) {
					objValue = {};
				}
				const nvmeKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();
				let temps = [];
				nvmeKeys.forEach((nvmeKey, index) => {
					try {
						let tempVal = NaN, tempMax = NaN, tempCrit = NaN;
						Object.keys(objValue[nvmeKey][sensorName]).forEach((secondLevelKey) => {
							if (secondLevelKey.endsWith('_input')) {
								tempVal = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));
							} else if (secondLevelKey.endsWith('_max')) {
								tempMax = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));
							} else if (secondLevelKey.endsWith('_crit')) {
								tempCrit = tempHelper.getTemp(parseFloat(objValue[nvmeKey][sensorName][secondLevelKey]));
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
							const tempStr = `Drive&nbsp;${index + 1}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, '0.0')}${tempHelper.getUnit()}</span>`;
							temps.push(tempStr);
						}
					} catch(e) { /*_*/ }
				});
				const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); });
				return '<div style="text-align: left; margin-left: 28px;">' + (result.length > 0 ? result.join('') : 'N/A') + '</div>';
			}
		},
EOF
	)
	#endregion nvme widget heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate nvme widget code" >&2
        exit 1
    fi
}

# Function to generate Fan widget
generate_fan_widget() {
	#region fan widget heredoc
	# use subshell to allow variable expansion
	(
		export DISPLAY_ZERO_SPEED_FANS
		cat <<'EOF' | envsubst '$DISPLAY_ZERO_SPEED_FANS' > "$1"
		{
			xtype: 'box',
			colspan: 2,
			html: gettext('Cooling'),
		},
		{
			itemId: 'speedFan',
			colspan: 2,
			printBar: false,
			title: gettext('Fan Speed(s)'),
			iconCls: 'fa fa-fw fa-snowflake-o',
			textField: 'sensorsOutput',
			renderer: function(value) {
				// ---
				let objValue;
				try {
					objValue = JSON.parse(value) || {};
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
						if ($DISPLAY_ZERO_SPEED_FANS != true && value === 0) {
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
					fanKeys.sort();
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
				return '<div style="text-align: left; margin-left: 28px;">' + (speeds.length > 0 ? speeds.join(' | ') : 'N/A') + '</div>';
			}
		},
EOF
	)
	#endregion fan widget heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate fan widget code" >&2
        exit 1
    fi
}

# Function to generate UPS widget
generate_hdd_widget() {
	#region hdd widget heredoc
	# use subshell to allow variable expansion
	(
		export HELPERCTORPARAMS
		export HDD_ITEMS_PER_ROW
		cat <<'EOF' | envsubst '$HDD_ITEMS_PER_ROW $HELPERCTORPARAMS' > "$1"
		{
			itemId: 'thermalHdd',
			colspan: 2,
			printBar: false,
			title: gettext('HDD/SSD Thermal State'),
			iconCls: 'fa fa-fw fa-thermometer-half',
			textField: 'sensorsOutput',
			renderer: function(value) {
				// sensors configuration
				const addressPrefix = "drivetemp-scsi-";
				const sensorName = "temp1";
				const tempHelper = Ext.create('PVE.mod.TempHelper', $HELPERCTORPARAMS);
				// display configuration
				const itemsPerRow = $HDD_ITEMS_PER_ROW;
				// ---
				let objValue;
				try {
					objValue = JSON.parse(value) || {};
				} catch(e) {
					objValue = {};
				}
				const drvKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();
				let temps = [];
				drvKeys.forEach((drvKey, index) => {
					try {
						let tempVal = NaN, tempMax = NaN, tempCrit = NaN;
						Object.keys(objValue[drvKey][sensorName]).forEach((secondLevelKey) => {
							if (secondLevelKey.endsWith('_input')) {
								tempVal = tempHelper.getTemp(parseFloat(objValue[drvKey][sensorName][secondLevelKey]));
							} else if (secondLevelKey.endsWith('_max')) {
								tempMax = tempHelper.getTemp(parseFloat(objValue[drvKey][sensorName][secondLevelKey]));
							} else if (secondLevelKey.endsWith('_crit')) {
								tempCrit = tempHelper.getTemp(parseFloat(objValue[drvKey][sensorName][secondLevelKey]));
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
							const tempStr = `Drive&nbsp;${index + 1}:&nbsp;<span style="${tempStyle}">${Ext.util.Format.number(tempVal, '0.0')}${tempHelper.getUnit()}</span>`;
							temps.push(tempStr);
						}
					} catch(e) { /*_*/ }
				});
				const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % itemsPerRow === 0 ? '<br>' : '&nbsp;| ') : ''); });
				return '<div style="text-align: left; margin-left: 28px;">' + (result.length > 0 ? result.join('') : 'N/A') + '</div>';
			}
		},
EOF
	)
	#endregion hdd widget heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate hhd widget code" >&2
        exit 1
    fi
}

# Function to generate RAM widget
generate_ram_widget() {
	#region ram widget heredoc
	# use subshell to allow variable expansion
	(
		export HELPERCTORPARAMS	
		cat <<'EOF' | envsubst '$HELPERCTORPARAMS' > "$1"
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
				const cpuTempHelper = Ext.create('PVE.mod.TempHelper', $HELPERCTORPARAMS);

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
						ramTemps.push(`${ramKey}:&nbsp${ramTemp}${cpuTempHelper.getUnit()}`);
					} catch(e) {
						console.error(`Error retrieving Ram Temp for ${ramTemps} in ${parentKey}:`, e); // Debug: Log specific error
					}
					});
				});
				return '<div style="text-align: left; margin-left: 28px;">' + (ramTemps.length > 0 ? ramTemps.join(' | ') : 'N/A') + '</div>';
			}
		},
EOF
	)
	#endregion ram widget heredoc
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to generate ram widget code" >&2
        exit 1
    fi
}

# Function to generate UPS widget
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
					return '<div style="text-align: right;"><span>N/A</span></div>';
				}

				// Helper function to get status color
				// Returns a CSS color string for non-default states, or null for default (no inline color)
				function getStatusColor(status) {
					if (!status) return '#999';
					const statusUpper = status.toUpperCase();
					if (statusUpper.includes('OL')) return null; // default (no explicit color)
					if (statusUpper.includes('OB')) return '#d9534f'; // Red for on battery
					if (statusUpper.includes('LB')) return '#d9534f'; // Red for low battery
					return '#f0ad4e'; // Orange for other states
				}

				// Helper function to get load/charge color
				// Returns null for default/good values so no inline style is emitted
				function getPercentageColor(value, isLoad = false) {
					if (!value || isNaN(value)) return '#999';
					const num = parseFloat(value);
					if (isLoad) {
						if (num >= 80) return '#d9534f'; // Red for high load
						if (num >= 60) return '#f0ad4e'; // Orange for medium load
						return null; // default (no explicit color)
					} else {
						// For battery charge
						if (num <= 20) return '#d9534f'; // Red for low charge
						if (num <= 50) return '#f0ad4e'; // Orange for medium charge
						return null; // default (no explicit color)
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

				// First line: Model info (no explicit color for default)
				let modelLine = '';
				if (upsModel) {
					modelLine = `<span>${upsModel}</span>`;
				} else {
					modelLine = `<span>N/A</span>`;
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
						statusColor = null; // default (no explicit color)
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
					if (runtime <= runtimeLowThreshold / 2) runtimeColor = '#d9534f'; // Red if less than half of low threshold
					else if (runtime <= runtimeLowThreshold) runtimeColor = '#f0ad4e'; // Orange if at low threshold
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

				displayItems.push(statusLine);

				// Combined battery and test line
				let batteryTestLine = '';
				if (batteryMfrDate) {
					batteryTestLine += '<span>Battery MFD: ' + batteryMfrDate + '</span>';
				} else {
					batteryTestLine += '<span>Battery MFD: N/A</span>';
				}

				if (testResult && !testResult.toLowerCase().includes('no test')) {
					const testColor = testResult.toLowerCase().includes('passed') ? null : '#d9534f';
					let testStyle = testColor ? ('color: ' + testColor + ';') : '';
					batteryTestLine += ' | <span style="' + testStyle + '">Test: ' + testResult + '</span>';
				} else {
					batteryTestLine += ' | <span>Test: N/A</span>';
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

#endregion widget generation functions

# Function to uninstall the modification
function uninstall_mod {
	msgb "=== Uninstalling Mod ==="

	check_root_privileges

	if [[ -z $(grep -e "$res->{sensorsOutput}" "$NODES_PM_FILE") ]] && [[ -z $(grep -e "$res->{systemInfo}" "$NODES_PM_FILE") ]]; then
		err "Mod is not installed."
	fi

	set_backup_directory
	info "Restoring modified files..."

	# Find the latest Nodes.pm file using the find command
	local latest_nodes_pm=$(find "$BACKUP_DIR" -name "Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_nodes_pm" ]; then
		# Remove the latest Nodes.pm file
		msgb "Restoring latest Nodes.pm from backup: $latest_nodes_pm to \"$NODES_PM_FILE\"."
		cp "$latest_nodes_pm" "$NODES_PM_FILE"
		info "Restored Nodes.pm successfully."
	else
		warn "No Nodes.pm backup files found."
	fi

	# Find the latest pvemanagerlib.js file using the find command
	local latest_pvemanagerlibjs=$(find "$BACKUP_DIR" -name "pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -n "$latest_pvemanagerlibjs" ]; then
		# Remove the latest pvemanagerlib.js file
		msgb "Restoring latest pvemanagerlib.js from backup: $latest_pvemanagerlibjs to \"$PVE_MANAGER_LIB_JS_FILE\"."
		cp "$latest_pvemanagerlibjs" "$PVE_MANAGER_LIB_JS_FILE"
		info "Restored pvemanagerlib.js successfully."
	else
		warn "No pvemanagerlib.js backup files found."
	fi

	if [ -n "$latest_nodes_pm" ] || [ -n "$latest_pvemanagerlibjs" ]; then
		# At least one of the variables is not empty, restart the proxy
		restart_proxy
	fi

	ask "Clear the browser cache to ensure all changes are visualized. (any key to continue)"
}

# Function to check if the modification is installed
check_mod_installation() {
    if [[ -n $(grep -F '$res->{sensorsOutput}' "$NODES_PM_FILE") ]] && \
       [[ -n $(grep -F '$res->{systemInfo}' "$NODES_PM_FILE") ]] && \
       [[ -n $(grep -E "itemId: 'thermal[[:alnum:]]*'" "$PVE_MANAGER_LIB_JS_FILE") ]]; then
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