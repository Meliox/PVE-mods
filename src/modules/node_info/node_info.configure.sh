#!/usr/bin/env bash
# node_info.configure.sh - Configure module for pve-mod node_info
#
# Sourced by pve-mod-configure. Requires CONFD_DIR and the helper functions
# (info, warn, err, ask, msgb) to be defined in the calling script before
# this file is sourced.
#
# Provides the standard four-function module API:
#   node_info_defaults    — set all variables to safe defaults
#   node_info_load_conf   — parse /etc/pve-mod/conf.d/node_info.conf
#   node_info_configure   — interactive hardware-detection wizard
#   node_info_write_conf  — write /etc/pve-mod/conf.d/node_info.conf

NODE_INFO_CONF="${CONFD_DIR}/node_info.conf"
KNOWN_CPU_SENSORS=("coretemp-isa-" "k10temp-pci-" "cpu_thermal-virtual-")

# --- utilities ---------------------------------------------------------------

sanitize_sensors_output() {
    local input="$1"
    echo "$input" | perl -0777 -pe '
        s/ERROR:.+\s(\w+):\s(.+)/"$1": 0.000,/g;
        s/ERROR:.+\s(\w+)!/"$1": 0.000,/g;
        s/,\s*(\})/$1/g;
        s/\bNaN\b/null/g;
        s/"SODIMM"\s*:\s*\{\s*"temp(\d+)_input"/"SODIMM $1": {\n  "temp$1_input"/g;
        s/"([^"]*Fan[^"]*)"\s*:\s*\{\s*"fan(\d+)_input"/"$1 $2": {\n  "fan$2_input"/g;
    ' | python3 -m json.tool 2>/dev/null || echo "$input"
}

_check_or_install_tool() {
    local cmd="$1" pkg="$2" description="$3"
    if command -v "$cmd" &>/dev/null; then
        info "$description is installed."
        return 0
    fi
    local choice
    choice=$(ask "$description is not installed. Install it now? (y/N)")
    case "$choice" in
        [yY])
            apt-get update -qq
            apt-get install -y "$pkg"
            command -v "$cmd" &>/dev/null && { info "$description installed."; return 0; } || \
                { warn "$description installation failed. Section will be skipped."; return 1; }
            ;;
        *)
            info "Skipping $description."
            return 1
            ;;
    esac
}

_check_nvidia_tool() {
    if command -v nvidia-smi &>/dev/null; then
        info "nvidia-smi is installed."
        return 0
    fi
    warn "nvidia-smi not found. NVIDIA monitoring requires NVIDIA drivers (not installable via apt)."
    return 1
}

# --- standard API ------------------------------------------------------------

node_info_defaults() {
    LM_SENSORS_ENABLED=0
    ENABLE_CPU=0; CPU_TEMP_TARGET="Core"
    ENABLE_RAM_TEMP=0; ENABLE_HDD_TEMP=0; ENABLE_NVME_TEMP=0; ENABLE_OTHER_TEMP=0
    ENABLE_FAN_SPEED=0; DISPLAY_ZERO_SPEED_FANS=0; TEMP_UNIT="C"
    ENABLE_INTEL_GPU_INFO=0; ENABLE_NVIDIA_GPU_INFO=0; ENABLE_AMD_GPU_INFO=0
    ENABLE_GPU_HISTORY=0
    ENABLE_UPS=0; UPS_DEVICE_NAME="ups@localhost"
    ENABLE_SYSTEM_INFO=0; SYSTEM_INFO_TYPE=1
    DEBUG_LM_SENSORS=0; DEBUG_LM_SENSORS_FILE="/tmp/sensors-output.json"
    DEBUG_INTEL=0;       DEBUG_INTEL_FILE="/tmp/intel-gpu-devices.txt"
                         DEBUG_INTEL_OUTPUT_FILE="/tmp/intel-gpu-top-output.txt"
    DEBUG_NVIDIA=0;      DEBUG_NVIDIA_OUTPUT_FILE="/tmp/nvidia-smi-output.csv"
                         DEBUG_NVIDIA_DEVICES_FILE="/tmp/nvidia-smi-devices.csv"
    DEBUG_AMD=0;         DEBUG_AMD_FILE="/tmp/amd-gpu-devices.json"
    DEBUG_UPS=0;         DEBUG_UPS_FILE="/tmp/ups-output.json"
    DEBUG_LOG=0;         DEBUG_LOG_FILE="/tmp/pve-mod-debug.log"
}

node_info_load_conf() {
    [[ -f "$NODE_INFO_CONF" ]] || return 0
    local line key val section=""
    while IFS= read -r line; do
        case "$line" in
            '#'*|'')   continue ;;
            '['*']')   section="${line#[}"; section="${section%]}"; continue ;;
        esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        case "${section}.${key}" in
            gpu.intel_enabled)              ENABLE_INTEL_GPU_INFO="$val" ;;
            gpu.nvidia_enabled)             ENABLE_NVIDIA_GPU_INFO="$val" ;;
            gpu.amd_enabled)                ENABLE_AMD_GPU_INFO="$val" ;;
            gpu.gpu_history)                ENABLE_GPU_HISTORY="$val" ;;
            lm_sensors.enabled)             LM_SENSORS_ENABLED="$val" ;;
            lm_sensors.enable_cpu)          ENABLE_CPU="$val" ;;
            lm_sensors.cpu_temp_target)     CPU_TEMP_TARGET="$val" ;;
            lm_sensors.enable_ram_temp)     ENABLE_RAM_TEMP="$val" ;;
            lm_sensors.enable_hdd_temp)     ENABLE_HDD_TEMP="$val" ;;
            lm_sensors.enable_nvme_temp)    ENABLE_NVME_TEMP="$val" ;;
            lm_sensors.enable_other_temp)   ENABLE_OTHER_TEMP="$val" ;;
            lm_sensors.enable_fan_speed)    ENABLE_FAN_SPEED="$val" ;;
            lm_sensors.display_zero_speed_fans) DISPLAY_ZERO_SPEED_FANS="$val" ;;
            lm_sensors.temp_unit)           TEMP_UNIT="$val" ;;
            ups.enabled)                    ENABLE_UPS="$val" ;;
            ups.device_name)                UPS_DEVICE_NAME="$val" ;;
            system_info.enabled)            ENABLE_SYSTEM_INFO="$val" ;;
            system_info.type)               SYSTEM_INFO_TYPE="$val" ;;
            debug.lm_sensors_mode)          DEBUG_LM_SENSORS="$val" ;;
            debug.lm_sensors_output_file)   DEBUG_LM_SENSORS_FILE="$val" ;;
            debug.intel_mode)               DEBUG_INTEL="$val" ;;
            debug.intel_devices_file)       DEBUG_INTEL_FILE="$val" ;;
            debug.intel_output_file)        DEBUG_INTEL_OUTPUT_FILE="$val" ;;
            debug.nvidia_mode)              DEBUG_NVIDIA="$val" ;;
            debug.nvidia_devices_file)      DEBUG_NVIDIA_DEVICES_FILE="$val" ;;
            debug.nvidia_output_file)       DEBUG_NVIDIA_OUTPUT_FILE="$val" ;;
            debug.amd_mode)                 DEBUG_AMD="$val" ;;
            debug.amd_devices_file)         DEBUG_AMD_FILE="$val" ;;
            debug.ups_mode)                 DEBUG_UPS="$val" ;;
            debug.ups_output_file)          DEBUG_UPS_FILE="$val" ;;
            debug.log_enabled)              DEBUG_LOG="$val" ;;
            debug.log_file)                 DEBUG_LOG_FILE="$val" ;;
        esac
    done < "$NODE_INFO_CONF"
}

#region node-info wizard
node_info_configure() {
    # Initialize all variables to off
    LM_SENSORS_ENABLED=0
    ENABLE_CPU=0; CPU_TEMP_TARGET="Core"
    ENABLE_RAM_TEMP=0; ENABLE_HDD_TEMP=0; ENABLE_NVME_TEMP=0; ENABLE_OTHER_TEMP=0
    ENABLE_FAN_SPEED=0; DISPLAY_ZERO_SPEED_FANS=0; TEMP_UNIT="C"
    ENABLE_INTEL_GPU_INFO=0; ENABLE_NVIDIA_GPU_INFO=0; ENABLE_AMD_GPU_INFO=0
    ENABLE_GPU_HISTORY=0
    ENABLE_UPS=0; UPS_DEVICE_NAME="ups@localhost"
    ENABLE_SYSTEM_INFO=0; SYSTEM_INFO_TYPE=1

    local lm_sensors_ok=false
    local sensors_detected=false

    if [[ "$DEBUG_LM_SENSORS" -eq 1 && -f "$DEBUG_LM_SENSORS_FILE" ]]; then
        info "[debug] Using sensor data from $DEBUG_LM_SENSORS_FILE"
        lm_sensors_ok=true; LM_SENSORS_ENABLED=1
    else
        _check_or_install_tool sensors lm-sensors "lm-sensors" && lm_sensors_ok=true && LM_SENSORS_ENABLED=1
    fi

    if [[ "$lm_sensors_ok" == true ]]; then
        local sensorsOutput
        if [[ "$DEBUG_LM_SENSORS" -eq 1 ]]; then
            sensorsOutput=$(cat "$DEBUG_LM_SENSORS_FILE")
        else
            sensorsOutput=$(sensors -j 2>/dev/null) || true
        fi

        local trimmedSensorsOutput
        trimmedSensorsOutput=$(echo "$sensorsOutput" | tr -d '[:space:]')
        if [[ -z "$trimmedSensorsOutput" || "$trimmedSensorsOutput" == "{}" ]]; then
            warn "lm-sensors is installed but reported no sensors."
            warn "No kernel sensor drivers appear to be loaded."
            warn "Run 'sensors-detect' and load the suggested modules, then re-run this configurator."
            warn "lm-sensors output is the foundation for this mod. Mod cannot be enabled without it."
            exit 0
            lm_sensors_ok=false
            LM_SENSORS_ENABLED=0
        fi
    fi

    if [[ "$lm_sensors_ok" == true ]]; then
        local sanitisedSensorsOutput
        sanitisedSensorsOutput=$(sanitize_sensors_output "$sensorsOutput")

        #region CPU
        msgb "\n=== Detecting CPU temperature sensors ==="
        local cpuList="" cpuCount=0
        for pattern in "${KNOWN_CPU_SENSORS[@]}"; do
            local found_cpus
            found_cpus=$(echo "$sanitisedSensorsOutput" | grep -o "\"${pattern}[^\"]*\"" || true | sed 's/"//g')
            if [[ -n "$found_cpus" ]]; then
                while read -r sensor; do
                    [[ -z "$sensor" ]] && continue
                    cpuCount=$((cpuCount + 1))
                    cpuList="${cpuList:+$cpuList,}$sensor"
                    ENABLE_CPU=1
                done <<< "$found_cpus"
            fi
        done
        if [[ "$ENABLE_CPU" -eq 1 ]]; then
            info "Detected CPU sensors ($cpuCount): $cpuList"
            sensors_detected=true
            local bRpiOnly=false
            if [[ "$cpuList" == *"cpu_thermal-virtual-"* ]] && \
               [[ "$cpuList" != *"coretemp-isa-"* ]] && \
               [[ "$cpuList" != *"k10temp-pci-"* ]]; then
                bRpiOnly=true
            fi
            if [[ "$bRpiOnly" == true ]]; then
                CPU_TEMP_TARGET="Core"
            else
                while true; do
                    local choice
                    choice=$(ask "Display temperatures for all cores [C] or average per CPU [a]? (C/a)")
                    case "$choice" in
                        [cC]|"") CPU_TEMP_TARGET="Core"; info "Showing per-core temperatures."; break ;;
                        [aA])    CPU_TEMP_TARGET="Package"; info "Showing average per-CPU temperature."; break ;;
                        *)       warn "Invalid input, choose C or a." ;;
                    esac
                done
            fi
        else
            warn "No CPU temperature sensors found."
        fi
        #endregion CPU

        #region RAM
        msgb "\n=== Detecting RAM temperature sensors ==="
        local ramCount
        ramCount=$(grep -c '"SODIMM[^"]*"' <<<"$sanitisedSensorsOutput" || true)
        if [[ "$ramCount" -gt 0 ]]; then
            info "Detected $ramCount RAM sensor(s)."
            ENABLE_RAM_TEMP=1; sensors_detected=true
        else
            warn "No RAM temperature sensors found."
        fi
        #endregion RAM

        #region HDD/SSD
        msgb "\n=== Detecting HDD/SSD temperature sensors ==="
        local hddList
        hddList=$(echo "$sanitisedSensorsOutput" | grep -o '"drivetemp-scsi[^"]*"' | sed 's/"//g' | wc -l || true)
        if [[ "$hddList" -gt 0 ]]; then
            info "Detected $hddList HDD/SSD sensor(s)."
            ENABLE_HDD_TEMP=1; sensors_detected=true
        else
            warn "No HDD/SSD temperature sensors found. (Requires kernel module 'drivetemp'.)"
        fi
        #endregion HDD/SSD

        #region NVMe
        msgb "\n=== Detecting NVMe temperature sensors ==="
        local nvmeCount
        nvmeCount=$(echo "$sanitisedSensorsOutput" | grep -c '"nvme[^"]*"' || true)
        if [[ "$nvmeCount" -gt 0 ]]; then
            info "Detected $nvmeCount NVMe sensor(s)."
            ENABLE_NVME_TEMP=1; sensors_detected=true
        else
            warn "No NVMe temperature sensors found."
        fi
        #endregion NVMe

        #region Other thermals
        msgb "\n=== Detecting other thermal sensors ==="
        local otherTempCount
        otherTempCount=$(echo "$sanitisedSensorsOutput" \
            | grep -Ev '"(coretemp|k10temp-pci|cpu_thermal-virtual|nvme|drivetemp-scsi|SODIMM|spd5118)[^"]*"' \
            | grep -c '"temp[0-9]*_input"' || true)

        if [[ "$otherTempCount" -gt 0 ]]; then
            info "Detected $otherTempCount other temperature reading(s)."
            ENABLE_OTHER_TEMP=1; sensors_detected=true
        else
            warn "No other temperature sensors found."
        fi
        #region Other thermals

        #region Fans
        msgb "\n=== Detecting fan speed sensors ==="
        local fanCount
        fanCount=$(grep -c 'fan[0-9]\+_input' <<<"$sanitisedSensorsOutput" || true)
        if [[ "$fanCount" -gt 0 ]]; then
            info "Detected $fanCount fan speed reading(s)."
            ENABLE_FAN_SPEED=1; sensors_detected=true
            local choice
            choice=$(ask "Display fans reporting zero speed? (Y/n)")
            case "$choice" in
                [nN]) DISPLAY_ZERO_SPEED_FANS=0; info "Zero-speed fans will be hidden." ;;
                *)    DISPLAY_ZERO_SPEED_FANS=1; info "Zero-speed fans will be shown." ;;
            esac
        else
            warn "No fan speed sensors found."
        fi
        #endregion Fans

        #region Temperature unit
        if [[ "$sensors_detected" == true ]]; then
            msgb "\n=== Temperature unit ==="
            local unit
            unit=$(ask "Display temperatures in Celsius [C] or Fahrenheit [f]? (C/f)")
            case "$unit" in
                [fF]) TEMP_UNIT="F"; info "Using Fahrenheit." ;;
                *)    TEMP_UNIT="C"; info "Using Celsius." ;;
            esac
        fi
        #endregion Temperature unit
    fi

    #region Intel GPU
    msgb "\n=== Detecting Intel GPU ==="
    local intelCards=""
    if [[ "$DEBUG_INTEL" -eq 1 && -f "$DEBUG_INTEL_FILE" ]]; then
        info "[debug] Using Intel GPU data from $DEBUG_INTEL_FILE"
        intelCards=$(cat "$DEBUG_INTEL_FILE")
        if [[ -n "$intelCards" ]]; then
            info "Intel GPU(s) detected (debug):"
            echo "$intelCards" | while IFS= read -r line; do echo "  $line"; done
            if [[ -f "$DEBUG_INTEL_OUTPUT_FILE" ]]; then
                info "[debug] Intel GPU stats output file found at $DEBUG_INTEL_OUTPUT_FILE"
                ENABLE_INTEL_GPU_INFO=1
            else
                warn "[debug] Intel GPU stats output file not found at $DEBUG_INTEL_OUTPUT_FILE. GPU stats graphs will be empty."
            fi
        else
            warn "No Intel GPUs in debug file."
        fi
    elif _check_or_install_tool intel_gpu_top intel-gpu-tools "Intel GPU tools (intel-gpu-tools)"; then
        intelCards=$(intel_gpu_top -L 2>/dev/null | grep -E '^card[0-9]+' || true)
        if [[ -n "$intelCards" ]]; then
            info "Intel GPU(s) detected:"
            echo "$intelCards" | while IFS= read -r line; do echo "  $line"; done
            ENABLE_INTEL_GPU_INFO=1

            # Write JSON devices file for debug/cache use by the Perl collector
            local json="["
            local first=1
            while IFS= read -r line; do
                # Parse: "card0  Intel Alderlake_n (Gen12)  pci:vendor=8086,device=46D0,card=0"
                if [[ "$line" =~ ^(card[0-9]+)[[:space:]]+(.+[^[:space:]])[[:space:]]+(pci:[^[:space:]]+) ]]; then
                    local card="${BASH_REMATCH[1]}"
                    local name="${BASH_REMATCH[2]}"
                    local path="${BASH_REMATCH[3]}"
                    name="${name%"${name##*[![:space:]]}"}"  # rtrim
                    [[ "$first" -eq 0 ]] && json+=","
                    json+="{\"card\":\"$card\",\"name\":\"$name\",\"path\":\"$path\",\"drm_path\":\"/dev/dri/$card\"}"
                    first=0
                fi
            done <<< "$intelCards"
            json+="]"
            echo "$json" > "$DEBUG_INTEL_FILE"
            info "Intel GPU device list saved to $DEBUG_INTEL_FILE"
        else
            warn "No Intel GPUs detected by intel_gpu_top."
        fi
    fi
    #endregion Intel GPU

    #region NVIDIA GPU
    msgb "\n=== Detecting NVIDIA GPU ==="
    if [[ "$DEBUG_NVIDIA" -eq 1 && -f "$DEBUG_NVIDIA_DEVICES_FILE" ]]; then
        info "[debug] Using NVIDIA GPU data from $DEBUG_NVIDIA_DEVICES_FILE"
        local nvidiaCards
        nvidiaCards=$(cat "$DEBUG_NVIDIA_DEVICES_FILE")
        if [[ -n "$nvidiaCards" ]]; then
            info "NVIDIA GPU(s) detected (debug):"
            echo "$nvidiaCards" | while IFS= read -r line; do echo "  $line"; done
            if [[ -f "$DEBUG_NVIDIA_OUTPUT_FILE" ]]; then
                info "[debug] NVIDIA GPU stats output file found at $DEBUG_NVIDIA_OUTPUT_FILE"
                ENABLE_NVIDIA_GPU_INFO=1
            else
                warn "[debug] NVIDIA GPU stats output file not found at $DEBUG_NVIDIA_OUTPUT_FILE. GPU stats graphs will be empty."
            fi
        else
            warn "No NVIDIA GPUs in debug file."
        fi
    elif _check_nvidia_tool; then
        local nvidiaCards
        nvidiaCards=$(nvidia-smi -L 2>/dev/null || true)
        if [[ -n "$nvidiaCards" ]]; then
            info "NVIDIA GPU(s) detected:"
            echo "$nvidiaCards" | while IFS= read -r line; do echo "  $line"; done
            ENABLE_NVIDIA_GPU_INFO=1
        else
            warn "No NVIDIA GPUs detected by nvidia-smi."
        fi
    fi
    #endregion NVIDIA GPU

    #region AMD GPU (placeholder)
    ENABLE_AMD_GPU_INFO=0
    #endregion AMD GPU

    #region GPU history
    if [[ "$ENABLE_INTEL_GPU_INFO" -eq 1 || "$ENABLE_NVIDIA_GPU_INFO" -eq 1 ]]; then
        msgb "\n=== GPU Historical Data ==="
        local choice
        choice=$(ask "Store historical GPU data for graphs? (y/N)")
        case "$choice" in
            [yY]) ENABLE_GPU_HISTORY=1; info "Historical GPU data will be stored." ;;
            *)    info "Historical GPU data disabled." ;;
        esac
    fi
    #endregion GPU history

    #region UPS
    msgb "\n=== UPS Information ==="
    local choiceUPS
    choiceUPS=$(ask "Enable UPS information? (y/N)")
    case "$choiceUPS" in
        [yY])
            local upsConn modelName upsOutput
            upsConn=$(ask "Enter UPS connection string (e.g. upsname@hostname[:port])")
            if [[ "$DEBUG_UPS" -eq 1 ]]; then
                if [[ -f "$DEBUG_UPS_FILE" ]]; then
                    info "[debug] Using UPS data from $DEBUG_UPS_FILE"
                else
                    warn "[debug] Debug mode for UPS is enabled but file not found at $DEBUG_UPS_FILE."
                fi
                upsOutput=$(cat "$DEBUG_UPS_FILE" || true)
                ENABLE_UPS=1
            elif _check_or_install_tool upsc nut-client "Network UPS Tools (upsc)" && [[ -n "$upsConn" ]]; then
                upsOutput=$(upsc "$upsConn" 2>/dev/null || true)
            else
                warn "Could not connect to UPS at '$upsConn'. UPS info will be disabled."
            fi
            if [[ -n "$upsOutput" ]]; then
                modelName=$(echo "$upsOutput" | grep "device.model:" | cut -d: -f2- | xargs)
                ENABLE_UPS=1
                UPS_DEVICE_NAME="$upsConn"
                info "Connected to UPS: $modelName at $upsConn"
            else
                warn "Could not connect to UPS at '$upsConn'. UPS info will be disabled."
                ENABLE_UPS=0
            fi
        ;;
        *) info "UPS information disabled." ;;
    esac
    #endregion UPS

    #region System info
    msgb "\n=== System Information ==="
    echo "  type 1) System information (manufacturer, product, serial)"
    dmidecode -t 1 2>/dev/null | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print "    "$0}' || true
    echo "  type 2) Baseboard/Motherboard information"
    dmidecode -t 2 2>/dev/null | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print "    "$0}' || true

    local choiceSys
    choiceSys=$(ask "Enable system information? (1/2/n)")
    case "$choiceSys" in
        1|"") ENABLE_SYSTEM_INFO=1; SYSTEM_INFO_TYPE=1; info "System information (type 1) will be shown." ;;
        2)    ENABLE_SYSTEM_INFO=1; SYSTEM_INFO_TYPE=2; info "Baseboard information (type 2) will be shown." ;;
        [nN]) info "System information disabled." ;;
        *)    warn "Invalid selection. Defaulting to type 1."; ENABLE_SYSTEM_INFO=1; SYSTEM_INFO_TYPE=1 ;;
    esac

    if [[ "$ENABLE_SYSTEM_INFO" -eq 1 ]]; then
        local cache_dir="/var/lib/pve-mod"
        mkdir -p "$cache_dir"
        local cache_file="${cache_dir}/dmidecode-type${SYSTEM_INFO_TYPE}.txt"
        dmidecode -t "$SYSTEM_INFO_TYPE" > "$cache_file" 2>/dev/null || true
        chmod 644 "$cache_file"
        info "DMI data cached to $cache_file"
    fi
    #endregion System info
}
#endregion node-info wizard

node_info_write_conf() {
    cat > "$NODE_INFO_CONF" <<EOF
# pve-mod :: node_info mod configuration
# Managed by pve-mod-configure. Re-run to update.

[gpu]
intel_enabled=${ENABLE_INTEL_GPU_INFO}
nvidia_enabled=${ENABLE_NVIDIA_GPU_INFO}
amd_enabled=${ENABLE_AMD_GPU_INFO}
gpu_history=${ENABLE_GPU_HISTORY}

[lm_sensors]
enabled=${LM_SENSORS_ENABLED}
enable_cpu=${ENABLE_CPU}
cpu_temp_target=${CPU_TEMP_TARGET}
enable_ram_temp=${ENABLE_RAM_TEMP}
enable_hdd_temp=${ENABLE_HDD_TEMP}
enable_nvme_temp=${ENABLE_NVME_TEMP}
enable_other_temp=${ENABLE_OTHER_TEMP}
enable_fan_speed=${ENABLE_FAN_SPEED}
display_zero_speed_fans=${DISPLAY_ZERO_SPEED_FANS}
temp_unit=${TEMP_UNIT}

[ups]
enabled=${ENABLE_UPS}
device_name=${UPS_DEVICE_NAME}

[system_info]
enabled=${ENABLE_SYSTEM_INFO}
type=${SYSTEM_INFO_TYPE}

# Debug mode: when a collector's mode is 1, the real tool is not required.
# Data is read from the file path instead. Useful for development/testing.
[debug]
lm_sensors_mode=${DEBUG_LM_SENSORS}
lm_sensors_output_file=${DEBUG_LM_SENSORS_FILE}
intel_mode=${DEBUG_INTEL}
intel_devices_file=${DEBUG_INTEL_FILE}
intel_output_file=${DEBUG_INTEL_OUTPUT_FILE}
nvidia_mode=${DEBUG_NVIDIA}
nvidia_devices_file=${DEBUG_NVIDIA_DEVICES_FILE}
nvidia_output_file=${DEBUG_NVIDIA_OUTPUT_FILE}
amd_mode=${DEBUG_AMD}
amd_devices_file=${DEBUG_AMD_FILE}
ups_mode=${DEBUG_UPS}
ups_output_file=${DEBUG_UPS_FILE}
log_enabled=${DEBUG_LOG}
log_file=${DEBUG_LOG_FILE}
EOF
    info "node_info configuration saved to $NODE_INFO_CONF"
}
