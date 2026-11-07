#!/usr/bin/env bash
# node_info.configure.sh - Configure module for pve-mods node_info
#
# Sourced by pve-mods-configure. Requires CONFD_DIR and the helper functions
# (info, warn, err, ask, msgb, section) to be defined in the calling script
# before this file is sourced.
#
# Provides the standard four-function module API:
#   node_info_defaults    — set all variables to safe defaults
#   node_info_load_conf   — parse /etc/pve-mods/conf.d/node_info.conf
#   node_info_configure   — interactive hardware-detection wizard
#   node_info_write_conf  — write /etc/pve-mods/conf.d/node_info.conf

NODE_INFO_CONF="${CONFD_DIR}/node_info.conf"

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

detect_sensor_counts() {
    python3 -c '
import json, re, sys

data = json.load(sys.stdin)
cpu_prefixes = ("coretemp-isa-", "k10temp-pci-", "cpu_thermal-virtual-")
ram_prefixes = ("spd5118-", "jc42-", "SODIMM")
cpu_sensors = []
ram_sensors = []
hdd_sensors = []
nvme_sensors = []
other_sensors = []
fan_sensors = []
ram_count = hdd_count = nvme_count = other_count = fan_count = 0

def temperature_features(chip):
    features = []
    for name, feature in chip.items():
        if not isinstance(feature, dict):
            continue
        reading = feature.get("input")
        if (isinstance(reading, dict)
                and reading.get("quantity") == "temperature"
                and isinstance(reading.get("value"), (int, float))):
            features.append((name, feature))
    return features

def joined_names(items):
    return ",".join(items) or "-"

for chip_name, chip in data.items():
    if not isinstance(chip, dict):
        continue
    temperatures = temperature_features(chip)
    if temperatures:
        ram_by_label = any(
            isinstance(feature.get("label"), str)
            and re.search(r"(?:SODIMM|DIMM)", feature["label"], re.I)
            for _, feature in temperatures
        )
        if chip_name.startswith(cpu_prefixes):
            cpu_sensors.append(chip_name)
        elif chip_name.startswith(ram_prefixes) or ram_by_label:
            ram_count += 1
            ram_sensors.append(chip_name)
        elif chip_name.startswith("drivetemp-scsi-"):
            hdd_count += 1
            hdd_sensors.append(chip_name)
        elif chip_name.startswith(("nvme-pci-", "drivetemp-nvme-")):
            nvme_count += 1
            nvme_sensors.append(chip_name)
        else:
            other_count += 1
            other_sensors.append(chip_name)

    for name, feature in chip.items():
        if not re.fullmatch(r"fan\d+", name) or not isinstance(feature, dict):
            continue
        reading = feature.get("input")
        if (isinstance(reading, dict)
                and reading.get("quantity") == "speed"
                and isinstance(reading.get("value"), (int, float))):
            fan_count += 1
            fan_sensors.append(f"{chip_name}/{name}")

print("\t".join(map(str, (
    len(cpu_sensors), ram_count, hdd_count, nvme_count,
    other_count, fan_count, joined_names(cpu_sensors), joined_names(ram_sensors),
    joined_names(hdd_sensors), joined_names(nvme_sensors),
    joined_names(other_sensors), joined_names(fan_sensors)
))))
    '
}

_check_or_install_tool() {
    local cmd="$1" pkg="$2" description="$3" unmet_msg="${4:-$3 is not installed.}"
    if command -v "$cmd" &>/dev/null; then
        info "$description is installed."
        return 0
    fi
    warn "$unmet_msg"
    local choice
    choice=$(ask "Install $description now, or skip and continue? (y/N)")
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
# Prompts with the current value pre-filled so it can be edited in place; Enter
# accepts it. Without a terminal (no readline) an empty reply keeps the value.
_ask_prefilled() {
    local label="$1" current="$2" reply
    read -r -e -i "$current" -p $'\001\e[1;36m\002'"${label}:"$'\001\e[0m\002 ' reply
    echo "${reply:-$current}"
}

# Prompts for a whole number in min..max, pre-filled with the current value and
# showing the default in brackets. Prints the result on stdout.
_ask_int() {
    local label="$1" current="$2" min="$3" max="$4" default="$5" reply hint=""
    [[ -n "$default" ]] && hint=" [default: $default]"
    while true; do
        reply=$(_ask_prefilled "$label ($min-$max)$hint" "$current")
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( 10#$reply >= min && 10#$reply <= max )); then
            echo "$((10#$reply))"; return
        fi
        warn "Enter a whole number from $min to $max." >&2
        current="$reply"
    done
}

# Prompts for y/n, pre-filled with the current 1/0 value and showing the default
# 1/0 in brackets. An empty current value means nothing is pre-filled and a blank
# reply counts as "no". Prints 1 or 0.
_ask_yes_no() {
    local label="$1" current="$2" default="$3" shown="n" hint="" reply blank_ok=0
    if [[ -z "$current" ]]; then shown=""; blank_ok=1; fi
    [[ "$current" == "1" ]] && shown="y"
    if [[ -n "$default" ]]; then
        [[ "$default" == "1" ]] && hint=" [default: y]" || hint=" [default: n]"
    fi
    while true; do
        reply=$(_ask_prefilled "$label (y/n)$hint" "$shown")
        case "$reply" in
            [yY]*) echo 1; return ;;
            [nN]*) echo 0; return ;;
            "") if (( blank_ok )); then echo 0; return; fi ;;
        esac
        warn "Answer y or n." >&2
        shown="$reply"
    done
}

# Prompts for one of the given choices (case-insensitive), pre-filled with the
# current choice and showing the default in brackets. An empty current value
# means nothing is pre-filled and a blank reply prints nothing. Prints the
# matching choice.
#   _ask_choice <label> <current> <default> <choice>...
_ask_choice() {
    local label="$1" current="$2" default="$3" reply choice options="" hint="" blank_ok=0
    shift 3
    for choice in "$@"; do options+="${options:+/}$choice"; done
    [[ -n "$default" ]] && hint=" [default: $default]"
    [[ -z "$current" ]] && blank_ok=1
    while true; do
        reply=$(_ask_prefilled "$label ($options)$hint" "$current")
        if [[ -z "$reply" ]] && (( blank_ok )); then return; fi
        for choice in "$@"; do
            [[ "${reply,,}" == "${choice,,}" ]] && { echo "$choice"; return; }
        done
        warn "Choose one of: $options." >&2
        current="$reply"
    done
}

# Echoes the saved value when a config file exists, otherwise the default, so a
# first run pre-fills the defaults rather than the zero-initialised variables.
_saved_or_default() {
    if [[ -f "$NODE_INFO_CONF" ]]; then echo "$1"; else echo "$2"; fi
}

_check_setcap_available() {
    command -v setcap &>/dev/null && return 0
    warn "'setcap' is not installed (needed to grant intel_gpu_top permission to run as www-data)."
    local choice
    choice=$(ask "Install libcap2-bin now, or skip and continue? (Y/n)")
    case "$choice" in
        [nN])
            return 1
            ;;
        *)
            apt-get update -qq
            apt-get install -y libcap2-bin
            command -v setcap &>/dev/null && return 0 || \
                { warn "libcap2-bin installation failed; cannot grant CAP_PERFMON."; return 1; }
            ;;
    esac
}

# Quick real-world check: can www-data actually read GPU perf counters via this binary?
_www_data_can_run_intel_gpu_top() {
    local bin="$1" out
    out=$(runuser -u www-data -- timeout 3 "$bin" -J -s 500 -o - 2>&1) || true
    [[ "$out" != *"Failed to initialize PMU"* && "$out" != *"Permission denied"* ]]
}

# Verifies (and if needed, requests to grant) the CAP_PERFMON capability that
# intel_gpu_top needs to run as www-data. Returns 1 if Intel GPU monitoring
# should stay disabled.
_verify_intel_gpu_permission() {
    local bin
    bin=$(command -v intel_gpu_top) || { warn "intel_gpu_top not found on PATH."; return 1; }

    if _www_data_can_run_intel_gpu_top "$bin"; then
        info "www-data can already collect Intel GPU performance data."
        return 0
    fi

    warn "www-data cannot read Intel GPU performance counters (intel_gpu_top requires CAP_PERFMON)."
    warn "See the Intel GPU 'Security' notes in the node_info readme before proceeding."

    _check_setcap_available || { warn "Skipping Intel GPU monitoring (cannot grant CAP_PERFMON)."; return 1; }

    local choice
    choice=$(ask "Grant CAP_PERFMON to $bin via setcap, so www-data can collect Intel GPU stats? (Y/n)")
    case "$choice" in
        [nN])
            info "Skipping Intel GPU monitoring (permission not granted)."
            return 1
            ;;
        *)
            setcap cap_perfmon+ep "$bin"
            if _www_data_can_run_intel_gpu_top "$bin"; then
                info "CAP_PERFMON granted; www-data can now collect Intel GPU stats."
                return 0
            fi
            warn "setcap did not resolve the permission problem; disabling Intel GPU monitoring."
            return 1
            ;;
    esac
}

_check_nvidia_tool() {
    local description="NVIDIA driver (nvidia-smi)"
    if command -v nvidia-smi &>/dev/null; then
        info "$description is installed."
        return 0
    fi
    warn "$description is not installed; NVIDIA GPU information cannot be detected without it."
    local choice
    choice=$(ask "Install $description now, or skip and continue? (y/N)")
    case "$choice" in
        [yY])
            apt-get update -qq
            apt-get install -y nvidia-driver
            command -v nvidia-smi &>/dev/null && { info "$description installed."; return 0; } || \
                { warn "$description installation failed (it may also require a reboot to take effect). Section will be skipped."; return 1; }
            ;;
        *)
            info "Skipping $description."
            return 1
            ;;
    esac
}

# Resolve the PCI vendor ID (lowercase, e.g. "8086") from either a
# "vendor=XXXX" descriptor or a "DDDD:BB:DD.F" address looked up via sysfs.
_get_pci_vendor_id() {
    local path="$1" vendor=""
    if [[ "$path" =~ vendor=([0-9a-fA-F]{4}) ]]; then
        vendor="${BASH_REMATCH[1]}"
    elif [[ "$path" =~ ^pci:([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]+)$ ]]; then
        local vfile="/sys/bus/pci/devices/${BASH_REMATCH[1]}/vendor"
        [[ -f "$vfile" ]] && vendor=$(cat "$vfile")
        vendor="${vendor#0x}"
    fi
    echo "${vendor,,}"
}

_is_intel_pci_device() {
    [[ "$(_get_pci_vendor_id "$1")" == "8086" ]]
}

# --- standard API ------------------------------------------------------------

node_info_defaults() {
    LM_SENSORS_ENABLED=0
    ENABLE_CPU=0
    ENABLE_RAM_TEMP=0; ENABLE_HDD_TEMP=0; ENABLE_NVME_TEMP=0; ENABLE_OTHER_TEMP=0
    ENABLE_FAN_SPEED=0; DISPLAY_ZERO_SPEED_FANS=0
    ENABLE_INTEL_GPU_INFO=0; ENABLE_NVIDIA_GPU_INFO=0; ENABLE_AMD_GPU_INFO=0
    ENABLE_GPU_HISTORY=0
    ENABLE_UPS=0; UPS_DEVICE_NAME="ups@localhost"
    ENABLE_SYSTEM_INFO=0; SYSTEM_INFO_TYPE=1; TEMP_UNIT="C"; IGNORE_TEMP_BELOW=5
    ENABLE_STORAGE_HEALTH=0; STORAGE_SMART_ENABLED=1
    STORAGE_LIFE_WARNING=20; STORAGE_LIFE_CRITICAL=10
    STORAGE_ZFS_INTERVAL=15; STORAGE_SMART_INTERVAL=1800; STORAGE_SMART_WAKE=0
    DATA_PULL_INTERVAL=1; COLLECTOR_TIMEOUT=10
    DEBUG_LM_SENSORS=0; DEBUG_LM_SENSORS_FILE="/tmp/sensors-output.json"
    DEBUG_INTEL=0;       DEBUG_INTEL_FILE="/tmp/intel-gpu-devices.txt"
                         DEBUG_INTEL_OUTPUT_FILE="/tmp/intel-gpu-top-output.txt"
    DEBUG_NVIDIA=0;      DEBUG_NVIDIA_OUTPUT_FILE="/tmp/nvidia-smi-output.csv"
                         DEBUG_NVIDIA_DEVICES_FILE="/tmp/nvidia-smi-devices.csv"
    DEBUG_AMD=0;         DEBUG_AMD_FILE="/tmp/amd-gpu-devices.json"
    DEBUG_UPS=0;         DEBUG_UPS_FILE="/tmp/ups-output.json"
    DEBUG_STORAGE_HEALTH=0
    DEBUG_ZPOOL_FILE="/tmp/zpool-status.txt"
    DEBUG_SMARTCTL_FILE="/tmp/smartctl-output.json"
    DEBUG_LOG=0;         DEBUG_LOG_FILE="/tmp/pve-mods-debug.log"
    DEBUG_MOD=0
}

# Same rule as the [intervals] parser in Config.pm: whole seconds, 1..2147483647.
# Prints the normalized value and succeeds, or fails for anything else.
_valid_interval() {
    local val="$1"
    [[ "$val" =~ ^[0-9]+$ ]] && (( ${#val} <= 10 )) || return 1
    (( 10#$val >= 1 && 10#$val <= 2147483647 )) || return 1
    echo "$((10#$val))"
}

# Loads one [intervals] value into the named variable; an invalid value keeps
# the current one, as Config.pm does at runtime.
_load_interval() {
    local var="$1" key="$2" val="$3" parsed
    val="${val%%#*}"                      # Config.pm also accepts inline comments
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    if parsed=$(_valid_interval "$val"); then
        printf -v "$var" '%s' "$parsed"
    else
        warn "Ignoring invalid [intervals] $key='$val' in $NODE_INFO_CONF (expected 1-2147483647); keeping ${!var}."
    fi
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
            lm_sensors.enable_ram_temp)     ENABLE_RAM_TEMP="$val" ;;
            lm_sensors.enable_hdd_temp)     ENABLE_HDD_TEMP="$val" ;;
            lm_sensors.enable_nvme_temp)    ENABLE_NVME_TEMP="$val" ;;
            lm_sensors.enable_other_temp)   ENABLE_OTHER_TEMP="$val" ;;
            lm_sensors.enable_fan_speed)    ENABLE_FAN_SPEED="$val" ;;
            lm_sensors.display_zero_speed_fans) DISPLAY_ZERO_SPEED_FANS="$val" ;;
            ups.enabled)                    ENABLE_UPS="$val" ;;
            ups.device_name)                UPS_DEVICE_NAME="$val" ;;
            system_info.enabled)            ENABLE_SYSTEM_INFO="$val" ;;
            system_info.type)               SYSTEM_INFO_TYPE="$val" ;;
            system_info.temp_unit)          TEMP_UNIT="$val" ;;
            system_info.ignore_temp_below)  IGNORE_TEMP_BELOW="$val" ;;
            storage_health.enabled)         ENABLE_STORAGE_HEALTH="$val" ;;
            storage_health.smart_enabled)   STORAGE_SMART_ENABLED="$val" ;;
            storage_health.life_warning_percent)  STORAGE_LIFE_WARNING="$val" ;;
            storage_health.life_critical_percent) STORAGE_LIFE_CRITICAL="$val" ;;
            storage_health.zfs_interval)    STORAGE_ZFS_INTERVAL="$val" ;;
            storage_health.smart_interval)  STORAGE_SMART_INTERVAL="$val" ;;
            storage_health.smart_wake_disks) STORAGE_SMART_WAKE="$val" ;;
            intervals.data_pull)            _load_interval DATA_PULL_INTERVAL data_pull "$val" ;;
            intervals.collector_timeout)    _load_interval COLLECTOR_TIMEOUT collector_timeout "$val" ;;
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
            debug.storage_health_mode)      DEBUG_STORAGE_HEALTH="$val" ;;
            debug.zpool_output_file)        DEBUG_ZPOOL_FILE="$val" ;;
            debug.smartctl_output_file)     DEBUG_SMARTCTL_FILE="$val" ;;
            debug.log_enabled)              DEBUG_LOG="$val" ;;
            debug.log_file)                 DEBUG_LOG_FILE="$val" ;;
            debug.mod_debug)                DEBUG_MOD="$val" ;;
        esac
    done < "$NODE_INFO_CONF"
}

#region node-info wizard
node_info_configure() {
    # Remember the saved answers so each prompt can pre-fill them (defaults on a first run)
    local saved_zero_fans saved_unit saved_ignore saved_gpu_history saved_ups saved_ups_name
    local saved_sysinfo saved_sysinfo_type saved_storage
    saved_zero_fans=$(_saved_or_default "$DISPLAY_ZERO_SPEED_FANS" 1)
    saved_unit=$(_saved_or_default "$TEMP_UNIT" C)
    saved_ignore=$(_saved_or_default "$IGNORE_TEMP_BELOW" 5)
    saved_gpu_history=$(_saved_or_default "$ENABLE_GPU_HISTORY" 0)
    saved_ups=$(_saved_or_default "$ENABLE_UPS" "")
    saved_ups_name=$(_saved_or_default "$UPS_DEVICE_NAME" "ups@localhost")
    saved_sysinfo=$(_saved_or_default "$ENABLE_SYSTEM_INFO" "")
    saved_sysinfo_type=$(_saved_or_default "$SYSTEM_INFO_TYPE" 1)
    saved_storage=$(_saved_or_default "$ENABLE_STORAGE_HEALTH" "")

    # Initialize all variables to off
    LM_SENSORS_ENABLED=0
    ENABLE_CPU=0
    ENABLE_RAM_TEMP=0; ENABLE_HDD_TEMP=0; ENABLE_NVME_TEMP=0; ENABLE_OTHER_TEMP=0
    ENABLE_FAN_SPEED=0; DISPLAY_ZERO_SPEED_FANS=0
    ENABLE_INTEL_GPU_INFO=0; ENABLE_NVIDIA_GPU_INFO=0; ENABLE_AMD_GPU_INFO=0
    ENABLE_GPU_HISTORY=0
    ENABLE_UPS=0; UPS_DEVICE_NAME="ups@localhost"
    ENABLE_SYSTEM_INFO=0; SYSTEM_INFO_TYPE=1; TEMP_UNIT="C"; IGNORE_TEMP_BELOW=5
    # Storage health thresholds and intervals are kept as loaded from the config
    ENABLE_STORAGE_HEALTH=0; STORAGE_SMART_ENABLED=1

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
            sensorsOutput=$(sensors -J 2>/dev/null) || true
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
        local sensorCounts cpuCount ramCount hddList nvmeCount otherTempCount fanCount
        local cpuList ramSensors hddSensors nvmeSensors otherSensors fanSensors
        sensorCounts=$(printf '%s\n' "$sanitisedSensorsOutput" | detect_sensor_counts 2>/dev/null) \
            || sensorCounts=$'0\t0\t0\t0\t0\t0\t-\t-\t-\t-\t-\t-'
        IFS=$'\t' read -r cpuCount ramCount hddList nvmeCount otherTempCount fanCount \
            cpuList ramSensors hddSensors nvmeSensors otherSensors fanSensors \
            <<< "$sensorCounts"

        #region CPU
        section "Detecting CPU temperature sensors"
        [[ "$cpuCount" -gt 0 ]] && ENABLE_CPU=1
        if [[ "$ENABLE_CPU" -eq 1 ]]; then
            info "Detected CPU sensors ($cpuCount): $cpuList"
            sensors_detected=true
        else
            warn "No CPU temperature sensors found."
        fi
        #endregion CPU

        #region RAM
        section "Detecting RAM temperature sensors"
        if [[ "$ramCount" -gt 0 ]]; then
            info "Detected RAM sensors ($ramCount): $ramSensors"
            ENABLE_RAM_TEMP=1; sensors_detected=true
        else
            warn "No RAM temperature sensors found."
        fi
        #endregion RAM

        #region HDD/SSD
        section "Detecting HDD/SSD temperature sensors"
        if [[ "$hddList" -gt 0 ]]; then
            info "Detected HDD/SSD sensors ($hddList): $hddSensors"
            ENABLE_HDD_TEMP=1; sensors_detected=true
        else
            warn "No HDD/SSD temperature sensors found. (Requires kernel module 'drivetemp'.)"
        fi
        #endregion HDD/SSD

        #region NVMe
        section "Detecting NVMe temperature sensors"
        if [[ "$nvmeCount" -gt 0 ]]; then
            info "Detected NVMe sensors ($nvmeCount): $nvmeSensors"
            ENABLE_NVME_TEMP=1; sensors_detected=true
        else
            warn "No NVMe temperature sensors found."
        fi
        #endregion NVMe

        #region Other thermals
        section "Detecting other thermal sensors"
        if [[ "$otherTempCount" -gt 0 ]]; then
            info "Detected other temperature sensors ($otherTempCount): $otherSensors"
            ENABLE_OTHER_TEMP=1; sensors_detected=true
        else
            warn "No other temperature sensors found."
        fi
        #endregion Other thermals

        #region Fans
        section "Detecting fan speed sensors"
        if [[ "$fanCount" -gt 0 ]]; then
            info "Detected fan speed readings ($fanCount): $fanSensors"
            ENABLE_FAN_SPEED=1; sensors_detected=true
            DISPLAY_ZERO_SPEED_FANS=$(_ask_yes_no "Display fans reporting zero speed?" "$saved_zero_fans" 1)
            if [[ "$DISPLAY_ZERO_SPEED_FANS" -eq 1 ]]; then
                info "Zero-speed fans will be shown."
            else
                info "Zero-speed fans will be hidden."
            fi
        else
            warn "No fan speed sensors found."
        fi
        #endregion Fans

        #region Temperature unit
        if [[ "$sensors_detected" == true ]]; then
            section "Temperature unit"
            local unit
            unit=$(_ask_choice "Display temperatures in Celsius or Fahrenheit" "$saved_unit" C C F)
            case "$unit" in
                F) TEMP_UNIT="F"; info "Using Fahrenheit." ;;
                *) TEMP_UNIT="C"; info "Using Celsius." ;;
            esac

            section "Ignore threshold"
            local default_c=5 default_display current_display entered
            [[ "$saved_ignore" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || saved_ignore="$default_c"
            if [[ "$TEMP_UNIT" == "F" ]]; then
                default_display=$(awk -v c="$default_c" 'BEGIN{printf "%.0f", c*9/5+32}')
                current_display=$(awk -v c="$saved_ignore" 'BEGIN{printf "%.1f", c*9/5+32}')
            else
                default_display="$default_c"
                current_display=$(awk -v c="$saved_ignore" 'BEGIN{printf "%.1f", c}')
            fi
            current_display="${current_display%.0}"
            while true; do
                entered=$(_ask_prefilled "Hide temperature readings below this value (°${TEMP_UNIT}) [default: ${default_display}]" "$current_display")
                [[ "$entered" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && break
                warn "Invalid number, please try again."
                current_display="$entered"
            done
            if [[ "$TEMP_UNIT" == "F" ]]; then
                IGNORE_TEMP_BELOW=$(awk -v f="$entered" 'BEGIN{printf "%.1f", (f-32)*5/9}')
            else
                IGNORE_TEMP_BELOW="$entered"
            fi
            info "Temperature readings below ${entered}°${TEMP_UNIT} will be hidden."
        fi
        #endregion Temperature unit
    fi

    #region GPU hardware detection
    section "Detecting GPU hardware"
    local gpuPciInfo="" hasIntelGpu=false hasNvidiaGpu=false hasAmdGpu=false
    if command -v lspci &>/dev/null; then
        gpuPciInfo=$(lspci -nn 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)
        if [[ -n "$gpuPciInfo" ]]; then
            info "Detected GPU controller(s):"
            echo "$gpuPciInfo" | while IFS= read -r line; do echo "  $line"; done
            grep -qi '\[8086:' <<<"$gpuPciInfo" && hasIntelGpu=true
            grep -qi '\[10de:' <<<"$gpuPciInfo" && hasNvidiaGpu=true
            grep -qi '\[1002:' <<<"$gpuPciInfo" && hasAmdGpu=true
        else
            warn "No VGA/3D/Display GPU controllers found via lspci."
        fi
    else
        warn "lspci not found; cannot detect GPU hardware by vendor. Every GPU vendor will be probed directly instead."
        hasIntelGpu=true; hasNvidiaGpu=true; hasAmdGpu=true
    fi
    #endregion GPU hardware detection

    #region Intel GPU
    section "Intel GPU"
    ENABLE_INTEL_GPU_INFO=0
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
    elif [[ "$hasIntelGpu" != true ]]; then
        info "No Intel GPU hardware detected. Skipping."
    elif ! _check_or_install_tool intel_gpu_top intel-gpu-tools "Intel GPU tools (intel-gpu-tools)" \
        "intel_gpu_top is not installed; Intel GPU information cannot be detected without it."; then
        warn "Skipping Intel GPU monitoring."
    else
        local rawIntelCards
        rawIntelCards=$(intel_gpu_top -L 2>/dev/null | grep -E '^card[0-9]+' || true)
        # Filter out non-Intel devices (e.g. AMD cards misdetected when intel-gpu-tools is installed on non-Intel hardware)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ (pci:[^[:space:]]+) ]] && _is_intel_pci_device "${BASH_REMATCH[1]}"; then
                intelCards+="${intelCards:+$'\n'}$line"
            fi
        done <<< "$rawIntelCards"
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

            _verify_intel_gpu_permission || ENABLE_INTEL_GPU_INFO=0
        else
            warn "No Intel GPUs detected by intel_gpu_top (or none had an Intel PCI vendor ID)."
        fi
    fi
    #endregion Intel GPU

    #region NVIDIA GPU
    section "NVIDIA GPU"
    ENABLE_NVIDIA_GPU_INFO=0
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
    elif [[ "$hasNvidiaGpu" != true ]]; then
        info "No NVIDIA GPU hardware detected. Skipping."
    elif ! _check_nvidia_tool; then
        : # already warned/asked inside _check_nvidia_tool
    else
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

    #region AMD GPU (disabled — data collection not yet implemented, see Collector/Amd.pm)
    ENABLE_AMD_GPU_INFO=0
    # section "AMD GPU"
    # if [[ "$DEBUG_AMD" -eq 1 && -f "$DEBUG_AMD_FILE" ]]; then
    #     info "[debug] Using AMD GPU data from $DEBUG_AMD_FILE"
    #     local amdCards
    #     amdCards=$(cat "$DEBUG_AMD_FILE")
    #     if [[ -n "$amdCards" ]]; then
    #         info "AMD GPU(s) detected (debug):"
    #         echo "$amdCards" | while IFS= read -r line; do echo "  $line"; done
    #         ENABLE_AMD_GPU_INFO=1
    #     else
    #         warn "No AMD GPUs in debug file."
    #     fi
    # elif [[ "$hasAmdGpu" != true ]]; then
    #     info "No AMD GPU hardware detected. Skipping."
    # elif ! _check_or_install_tool rocm-smi rocm-smi "AMD GPU tools (rocm-smi)" \
    #     "rocm-smi is not installed; AMD GPU information cannot be detected without it."; then
    #     warn "Skipping AMD GPU monitoring."
    # else
    #     warn "AMD GPU hardware and rocm-smi were detected, but AMD GPU data collection is not yet implemented in this pve-mods release."
    # fi
    #endregion AMD GPU

    #region GPU history
    ENABLE_GPU_HISTORY=0
    if [[ "$ENABLE_INTEL_GPU_INFO" -eq 1 || "$ENABLE_NVIDIA_GPU_INFO" -eq 1 ]]; then
        section "GPU Graphs"
        echo "The node summary page shows one graph per GPU. Choose where its data comes from:"
        echo "  1) Live only        - graphs fill from live samples while the page is open (default)"
        echo "  2) Record history   - samples are stored in RRD files, so past hours, days and years can be graphed"
        warn "Recording history keeps the GPU collectors (intel_gpu_top / nvidia-smi) running around the clock, even when nobody has the web UI open. This consumes CPU continuously."
        local choiceHistory shownHistory=1
        [[ "$saved_gpu_history" == "1" ]] && shownHistory=2
        choiceHistory=$(_ask_choice "GPU graph data: 1=live only, 2=record history" "$shownHistory" 1 1 2)
        case "$choiceHistory" in
            2) ENABLE_GPU_HISTORY=1; info "GPU history will be recorded (CPU is used continuously)." ;;
            *) info "GPU graphs will use live data only." ;;
        esac
    fi
    #endregion GPU history

    #region UPS
    section "UPS Information"
    local choiceUPS
    choiceUPS=$(_ask_yes_no "Enable UPS information?" "$saved_ups")
    case "$choiceUPS" in
        1)
            local upsConn modelName upsOutput
            upsConn=$(_ask_prefilled "Enter UPS connection string, e.g. upsname@hostname[:port] [default: ups@localhost]" "$saved_ups_name")
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

    #region Storage health
    section "Storage Health"
    local choiceStorage
    choiceStorage=$(_ask_yes_no "Enable storage health information?" "$saved_storage")
    case "$choiceStorage" in
        1)
            ENABLE_STORAGE_HEALTH=1
            if [[ "$DEBUG_STORAGE_HEALTH" -eq 1 ]]; then
                info "[debug] Using storage data from $DEBUG_ZPOOL_FILE and $DEBUG_SMARTCTL_FILE"
            elif ! _check_or_install_tool smartctl smartmontools "smartmontools (smartctl)" \
                    "smartmontools is not installed. SMART drive health needs it; ZFS pool health does not."; then
                STORAGE_SMART_ENABLED=0
                warn "SMART checks disabled. Only ZFS pool health will be shown."
            fi
            info "Storage health will be shown on the node Summary."

            echo "  Each value is pre-filled; press Enter to accept it or edit it first."
            STORAGE_ZFS_INTERVAL=$(_ask_int "ZFS pool check interval in seconds, while the Summary is open" "$STORAGE_ZFS_INTERVAL" 5 3600 15)
            if [[ "$STORAGE_SMART_ENABLED" -eq 1 ]]; then
                STORAGE_SMART_INTERVAL=$(_ask_int "SMART check interval in seconds for spinning drives" "$STORAGE_SMART_INTERVAL" 60 86400 1800)
                STORAGE_LIFE_WARNING=$(_ask_int "Warn when SSD/NVMe life remaining is at or below (%)" "$STORAGE_LIFE_WARNING" 0 100 20)
                STORAGE_LIFE_CRITICAL=$(_ask_int "Critical when SSD/NVMe life remaining is at or below (%)" "$STORAGE_LIFE_CRITICAL" 0 100 10)
                if (( STORAGE_LIFE_WARNING < STORAGE_LIFE_CRITICAL )); then
                    warn "The warning level cannot be below the critical level. Using ${STORAGE_LIFE_CRITICAL}% for both."
                    STORAGE_LIFE_WARNING="$STORAGE_LIFE_CRITICAL"
                fi
                STORAGE_SMART_WAKE=$(_ask_yes_no "Allow SMART checks to wake sleeping drives?" "$STORAGE_SMART_WAKE" 0)
            fi
        ;;
        *) info "Storage health information disabled." ;;
    esac
    #endregion Storage health

    #region System info
    section "System Information"
    echo "  type 1) System information (manufacturer, product, serial)"
    dmidecode -t 1 2>/dev/null | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print "    "$0}' || true
    echo "  type 2) Baseboard/Motherboard information"
    dmidecode -t 2 2>/dev/null | awk -F': ' '/Manufacturer|Product Name|Serial Number/ {print "    "$0}' || true

    local choiceSys shownSys=""
    if [[ "$saved_sysinfo" == "1" ]]; then shownSys="$saved_sysinfo_type"; elif [[ -n "$saved_sysinfo" ]]; then shownSys=n; fi
    [[ -z "$shownSys" || "$shownSys" == "1" || "$shownSys" == "2" || "$shownSys" == "n" ]] || shownSys=1
    choiceSys=$(_ask_choice "Enable system information?" "$shownSys" "" 1 2 n)
    case "$choiceSys" in
        1) ENABLE_SYSTEM_INFO=1; SYSTEM_INFO_TYPE=1; info "System information (type 1) will be shown." ;;
        2) ENABLE_SYSTEM_INFO=1; SYSTEM_INFO_TYPE=2; info "Baseboard information (type 2) will be shown." ;;
        *) info "System information disabled." ;;
    esac

    if [[ "$ENABLE_SYSTEM_INFO" -eq 1 ]]; then
        local cache_dir="/var/lib/pve-mods"
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
# pve-mods :: node_info mod configuration
# Managed by pve-mods-configure. Re-run to update.

[gpu]
intel_enabled=${ENABLE_INTEL_GPU_INFO}
nvidia_enabled=${ENABLE_NVIDIA_GPU_INFO}
amd_enabled=${ENABLE_AMD_GPU_INFO}
gpu_history=${ENABLE_GPU_HISTORY}

[lm_sensors]
enabled=${LM_SENSORS_ENABLED}
enable_cpu=${ENABLE_CPU}
enable_ram_temp=${ENABLE_RAM_TEMP}
enable_hdd_temp=${ENABLE_HDD_TEMP}
enable_nvme_temp=${ENABLE_NVME_TEMP}
enable_other_temp=${ENABLE_OTHER_TEMP}
enable_fan_speed=${ENABLE_FAN_SPEED}
display_zero_speed_fans=${DISPLAY_ZERO_SPEED_FANS}

[ups]
enabled=${ENABLE_UPS}
device_name=${UPS_DEVICE_NAME}

[storage_health]
enabled=${ENABLE_STORAGE_HEALTH}
smart_enabled=${STORAGE_SMART_ENABLED}
life_warning_percent=${STORAGE_LIFE_WARNING}
life_critical_percent=${STORAGE_LIFE_CRITICAL}
zfs_interval=${STORAGE_ZFS_INTERVAL}
smart_interval=${STORAGE_SMART_INTERVAL}
smart_wake_disks=${STORAGE_SMART_WAKE}

# Advanced, not prompted by the wizard: edit here, then restart pveproxy.
# Whole seconds, 1-2147483647. See the node_info readme before changing them.
[intervals]
# Seconds between collector data polls
data_pull=${DATA_PULL_INTERVAL}
# Stop collectors after this many seconds without a request
collector_timeout=${COLLECTOR_TIMEOUT}

[system_info]
enabled=${ENABLE_SYSTEM_INFO}
type=${SYSTEM_INFO_TYPE}
temp_unit=${TEMP_UNIT}
ignore_temp_below=${IGNORE_TEMP_BELOW}

# Debug mode: when a collector's mode is 1, the real tool is not required.
# Data is read from the file path instead. Useful for development/testing.
# Note: debug settings are only read at pveproxy startup — restart pveproxy
# after changing them. Debug output goes to the journal (journalctl -u pveproxy),
# plus log_file if log_enabled=1.
[debug]
mod_debug=${DEBUG_MOD}
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
storage_health_mode=${DEBUG_STORAGE_HEALTH}
zpool_output_file=${DEBUG_ZPOOL_FILE}
smartctl_output_file=${DEBUG_SMARTCTL_FILE}
log_enabled=${DEBUG_LOG}
log_file=${DEBUG_LOG_FILE}
EOF
    info "node_info configuration saved to $NODE_INFO_CONF"
}
