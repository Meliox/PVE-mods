#!/usr/bin/env bash
#
# This bash script installs a modification to the Proxmox Virtual Environment (PVE)
# web user interface (UI) to display NVIDIA GPU information.
#
# Author: Based on pve-mod-gui-sensors.sh by Meliox
# License: MIT
#

################### Configuration #############

# Temperature thresholds (Celsius)
TEMP_WARNING=70
TEMP_CRITICAL=85

# Overwrite default backup location (leave empty for default ~/PVE-MODS)
BACKUP_DIR=""

##################### DO NOT EDIT BELOW #######################

# This script's working directory
SCRIPT_CWD="$(dirname "$(readlink -f "$0")")"

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

# Prompts (cyan)
function ask() {
    local prompt="$1"
    local response
    read -p $'\n\e[1;36m'"${prompt}:"$'\e[0m ' response
    echo "$response"
}
#endregion message tools

# Function to display usage information
function usage {
    msgb "\nUsage:\n$0 [install | uninstall]\n"
    msgb "Options:"
    echo "  install     Install the NVIDIA GPU monitoring modification"
    echo "  uninstall   Remove the modification and restore original files"
    echo ""
    exit 1
}

# System checks
function check_root_privileges() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root. Please run it with 'sudo $0'."
    fi
    info "Root privileges verified."
}

# Check if nvidia-smi is available
function check_nvidia_smi() {
    if ! command -v nvidia-smi &>/dev/null; then
        err "nvidia-smi is not installed or not in PATH. Please install NVIDIA drivers first."
    fi
    info "nvidia-smi found."
}

# Detect NVIDIA GPUs
function detect_gpus() {
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1)
    
    if [[ -z "$gpu_count" ]] || [[ "$gpu_count" -eq 0 ]]; then
        err "No NVIDIA GPUs detected by nvidia-smi."
    fi
    
    echo "$gpu_count"
}

# Configure installation options
function configure() {
    msgb "\n=== Detecting NVIDIA GPUs ==="
    
    check_nvidia_smi
    
    local gpu_count
    gpu_count=$(detect_gpus)
    
    info "Detected $gpu_count NVIDIA GPU(s):"
    
    # Display detected GPUs
    nvidia-smi --query-gpu=index,name --format=csv,noheader 2>/dev/null | while read -r line; do
        echo "  GPU $line"
    done
    
    # Temperature unit selection
    msgb "\n=== Display Settings ==="
    local unit
    unit=$(ask "Display temperatures in Celsius [C] or Fahrenheit [f]? (C/f)")
    case "$unit" in
        [fF])
            TEMP_UNIT="F"
            info "Using Fahrenheit."
            ;;
        *)
            TEMP_UNIT="C"
            info "Using Celsius."
            ;;
    esac
}

# Function to check if the modification is already installed
function check_mod_installation() {
    if grep -q 'nvidiaGpuOutput' "$NODES_PM_FILE" 2>/dev/null; then
        err "NVIDIA GPU mod is already installed. Please uninstall first before reinstalling."
    fi
}

# Set backup directory
function set_backup_directory() {
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$HOME/PVE-MODS"
        info "Using default backup directory: $BACKUP_DIR"
    else
        if [[ ! -d "$BACKUP_DIR" ]]; then
            err "The specified backup directory does not exist: $BACKUP_DIR"
        fi
        info "Using custom backup directory: $BACKUP_DIR"
    fi
}

# Create backup directory
function create_backup_directory() {
    set_backup_directory
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || {
            err "Failed to create backup directory: $BACKUP_DIR. Please check permissions."
        }
        info "Created backup directory: $BACKUP_DIR"
    else
        info "Backup directory already exists: $BACKUP_DIR"
    fi
}

# Create file backup
function create_file_backup() {
    local source_file="$1"
    local timestamp="$2"
    local filename
    
    filename=$(basename "$source_file")
    local backup_file="$BACKUP_DIR/nvidia-gpu.${filename}.$timestamp"
    
    [[ -f "$source_file" ]] || err "Source file does not exist: $source_file"
    [[ -r "$source_file" ]] || err "Cannot read source file: $source_file"
    
    cp "$source_file" "$backup_file" || err "Failed to create backup: $backup_file"
    
    # Verify backup integrity
    if ! cmp -s "$source_file" "$backup_file"; then
        err "Backup verification failed for: $backup_file"
    fi
    
    info "Created backup: $backup_file"
}

# Perform backup of files
function perform_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
    msgb "\n=== Creating backups of modified files ==="
    
    create_backup_directory
    create_file_backup "$NODES_PM_FILE" "$timestamp"
    create_file_backup "$PVE_MANAGER_LIB_JS_FILE" "$timestamp"
}

# Restart pveproxy service
function restart_proxy() {
    info "Restarting PVE proxy..."
    systemctl restart pveproxy
}

# Insert NVIDIA GPU data collection into Nodes.pm
function insert_node_info() {
    msgb "\n=== Inserting NVIDIA GPU data retrieval code ==="
    
    local nvidia_cmd='nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,fan.speed --format=csv,noheader,nounits 2>/dev/null'
    
    # Insert the nvidia-smi command into Nodes.pm
    # This adds a new field to the API response
    sed -i "/my \$dinfo = df('\/', 1);/i\\
# Collect NVIDIA GPU data\\
\$res->{nvidiaGpuOutput} = \`$nvidia_cmd\`;\\
" "$NODES_PM_FILE"
    
    if [[ $? -ne 0 ]]; then
        err "Failed to insert NVIDIA GPU retrieval code into Nodes.pm"
    fi
    
    info "NVIDIA GPU retriever added to \"$NODES_PM_FILE\"."
}

# Insert GPU widget before the 'cpus' item in pvemanagerlib.js
function insert_gpu_widget() {
    msgb "\n=== Inserting GPU widget into UI ==="
    
    local temp_js_file="/tmp/nvidia_gpu_widget.js"
    
    # Generate the GPU widget JavaScript code with proper indentation
    # Indentation matches the pvemanagerlib.js style (tab-based)
    cat > "$temp_js_file" << 'WIDGET_EOF'
	{
	    xtype: 'box',
	    colspan: 2,
	    html: gettext('GPU(s)'),
	},
	{
	    itemId: 'nvidiaGpu',
	    colspan: 2,
	    printBar: false,
	    title: gettext('NVIDIA GPU Status'),
	    iconCls: 'fa fa-fw fa-television',
	    textField: 'nvidiaGpuOutput',
	    renderer: function(value) {
	        if (!value || value.trim() === '') {
	            return '<div style="text-align: left; margin-left: 28px;">No NVIDIA GPUs detected or nvidia-smi not available</div>';
	        }
	        
	        // Temperature conversion settings
WIDGET_EOF

    # Add temperature settings based on user selection
    if [[ "$TEMP_UNIT" == "F" ]]; then
        cat >> "$temp_js_file" << 'WIDGET_EOF'
	        var toFahrenheit = true;
	        var tempUnit = '°F';
	        var tempWarning = 158; // 70°C in F
	        var tempCritical = 185; // 85°C in F
WIDGET_EOF
    else
        cat >> "$temp_js_file" << 'WIDGET_EOF'
	        var toFahrenheit = false;
	        var tempUnit = '°C';
	        var tempWarning = 70;
	        var tempCritical = 85;
WIDGET_EOF
    fi

    # Continue with the rest of the widget code
    cat >> "$temp_js_file" << 'WIDGET_EOF'
	        
	        function convertTemp(celsius) {
	            if (toFahrenheit) {
	                return (celsius * 9 / 5) + 32;
	            }
	            return celsius;
	        }
	        
	        function formatTemp(celsius) {
	            var temp = convertTemp(celsius);
	            var style = '';
	            var convertedWarning = toFahrenheit ? tempWarning : 70;
	            var convertedCritical = toFahrenheit ? tempCritical : 85;
	            
	            if (temp >= convertedCritical) {
	                style = 'color: #ff4444; font-weight: bold;';
	            } else if (temp >= convertedWarning) {
	                style = 'color: #FFC300; font-weight: bold;';
	            }
	            return '<span style="' + style + '">' + temp.toFixed(0) + tempUnit + '</span>';
	        }
	        
	        function formatMemory(used, total) {
	            var percent = (used / total * 100).toFixed(1);
	            var style = '';
	            if (percent >= 90) {
	                style = 'color: #ff4444; font-weight: bold;';
	            } else if (percent >= 75) {
	                style = 'color: #FFC300;';
	            }
	            return '<span style="' + style + '">' + used.toLocaleString() + ' of ' + total.toLocaleString() + ' MiB (' + percent + '%)</span>';
	        }
	        
	        function formatPower(draw, limit) {
	            // Handle NaN power draw (some GPUs don't report power)
	            if (isNaN(draw)) {
	                draw = 0;
	            }
	            if (isNaN(limit) || limit === 0) {
	                return '<span>' + draw.toFixed(0) + 'W</span>';
	            }
	            var percent = (draw / limit * 100);
	            var style = '';
	            if (percent >= 90) {
	                style = 'color: #ff4444; font-weight: bold;';
	            } else if (percent >= 75) {
	                style = 'color: #FFC300;';
	            }
	            return '<span style="' + style + '">' + draw.toFixed(0) + ' of ' + limit.toFixed(0) + 'W</span>';
	        }
	        
	        function formatUtilization(util) {
	            var style = '';
	            if (util >= 90) {
	                style = 'color: #FFC300;';
	            }
	            return '<span style="' + style + '">' + util + '%</span>';
	        }
	        
	        function formatFan(fan) {
	            if (fan === null || fan === undefined || isNaN(fan) || fan === '[Not Supported]' || fan === '') {
	                return '<span style="color: #888;">N/A</span>';
	            }
	            return fan + '%';
	        }
	        
	        var lines = value.trim().split('\n');
	        var result = [];
	        
	        for (var i = 0; i < lines.length; i++) {
	            var line = lines[i].trim();
	            if (!line) continue;
	            
	            var parts = line.split(',').map(function(p) { return p.trim(); });
	            
	            if (parts.length < 10) continue;
	            
	            var gpuIndex = parts[0];
	            var gpuName = parts[1];
	            var temp = parseFloat(parts[2]);
	            var gpuUtil = parseInt(parts[3], 10);
	            var memUtil = parseInt(parts[4], 10);
	            var memUsed = parseFloat(parts[5]);
	            var memTotal = parseFloat(parts[6]);
	            var powerDraw = parseFloat(parts[7]);
	            var powerLimit = parseFloat(parts[8]);
	            var fanSpeed = parts[9];
	            
	            // Parse fan speed (may be [Not Supported] or a number)
	            var fanValue = parseFloat(fanSpeed);
	            if (isNaN(fanValue)) {
	                fanValue = null;
	            }
	            
	            var gpuHtml = '<div style="margin-bottom: 8px;">';
	            gpuHtml += '<div style="font-weight: bold; margin-bottom: 2px;">GPU ' + gpuIndex + ': ' + gpuName + '</div>';
	            gpuHtml += '<div style="margin-left: 10px;">';
	            gpuHtml += 'Temp: ' + formatTemp(temp);
	            gpuHtml += ' &nbsp;|&nbsp; GPU: ' + formatUtilization(gpuUtil);
	            gpuHtml += ' &nbsp;|&nbsp; Mem: ' + formatMemory(memUsed, memTotal);
	            gpuHtml += ' &nbsp;|&nbsp; Power: ' + formatPower(powerDraw, powerLimit);
	            gpuHtml += ' &nbsp;|&nbsp; Fan: ' + formatFan(fanValue);
	            gpuHtml += '</div></div>';
	            
	            result.push(gpuHtml);
	        }
	        
	        if (result.length === 0) {
	            return '<div style="text-align: left; margin-left: 28px;">No GPU data available</div>';
	        }
	        
	        return '<div style="text-align: left; margin-left: 28px;">' + result.join('') + '</div>';
	    }
	},
WIDGET_EOF

    if [[ $? -ne 0 ]]; then
        err "Failed to generate GPU widget code"
    fi
    
    # Insert the widget BEFORE the 'cpus' item
    # We use perl for reliable multi-line pattern matching and insertion
    # The BEGIN block reads the widget file before processing the main file
    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/nvidia_gpu_widget.js") or die "Cannot open widget file: $!";
            local $/;
            $::widget = <$fh>;
            close($fh);
        }
        # Find the cpus item within StatusView and insert widget before it
        s/(Ext\.define\('\''PVE\.node\.StatusView'\''.*?items:\s*\[.*?)({\s*itemId:\s*'\''cpus'\'')/$1$::widget$2/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"
    
    local insert_status=$?
    
    # Verify the insertion succeeded
    if [[ $insert_status -ne 0 ]]; then
        rm -f "$temp_js_file"
        err "Failed to insert GPU widget into pvemanagerlib.js (perl error)"
    fi
    
    # Verify the widget was actually inserted by checking for our itemId
    if ! grep -q "itemId: 'nvidiaGpu'" "$PVE_MANAGER_LIB_JS_FILE"; then
        rm -f "$temp_js_file"
        err "Widget insertion verification failed - nvidiaGpu itemId not found in file"
    fi
    
    rm -f "$temp_js_file"
    info "GPU widget inserted into \"$PVE_MANAGER_LIB_JS_FILE\"."
}

# Main installation function
function install_mod() {
    msgb "\n=== Preparing NVIDIA GPU mod installation ==="
    
    check_root_privileges
    check_mod_installation
    configure
    perform_backup
    
    insert_node_info
    insert_gpu_widget
    
    msgb "\n=== Finalizing installation ==="
    
    restart_proxy
    
    info "Installation completed successfully."
    msgb "\nIMPORTANT: Clear your browser cache (Ctrl+Shift+R) to see the changes."
}

# Uninstall the modification
function uninstall_mod() {
    msgb "\n=== Uninstalling NVIDIA GPU Mod ==="
    
    check_root_privileges
    
    # Check if mod is installed
    if ! grep -q 'nvidiaGpuOutput' "$NODES_PM_FILE" 2>/dev/null; then
        err "NVIDIA GPU mod is not installed."
    fi
    
    set_backup_directory
    
    # Check for other mods that would be affected by backup restoration
    local other_mods_detected=false
    local detected_mods=""
    
    if grep -q 'sensorsOutput' "$NODES_PM_FILE" 2>/dev/null; then
        other_mods_detected=true
        detected_mods="pve-mod-gui-sensors"
    fi
    
    if [[ "$other_mods_detected" == true ]]; then
        warn "Other PVE mods detected: $detected_mods"
        warn "Restoring from backup will remove ALL mods installed after the nvidia-gpu backup was created."
        msgb "\nYou have two options:"
        echo "  1) Continue - Restore backup, then reinstall other mods afterward"
        echo "  2) Cancel - Manually remove nvidia-gpu code from files instead"
        echo ""
        local confirm
        confirm=$(ask "Continue with backup restoration? (y/N)")
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            info "Uninstall cancelled."
            msgb "\nTo manually remove, edit these files:"
            echo "  - $NODES_PM_FILE (remove nvidiaGpuOutput lines)"
            echo "  - $PVE_MANAGER_LIB_JS_FILE (remove nvidiaGpu widget)"
            exit 0
        fi
    fi
    
    info "Restoring modified files..."
    
    # Find the latest Nodes.pm backup
    local latest_nodes_pm
    latest_nodes_pm=$(find "$BACKUP_DIR" -name "nvidia-gpu.Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')
    
    if [[ -n "$latest_nodes_pm" ]]; then
        msgb "Restoring Nodes.pm from backup: $latest_nodes_pm"
        cp "$latest_nodes_pm" "$NODES_PM_FILE"
        info "Restored Nodes.pm successfully."
    else
        warn "No Nodes.pm backup found. Attempting manual removal..."
        # Remove the nvidia-smi lines manually
        sed -i '/# Collect NVIDIA GPU data/,/nvidiaGpuOutput.*nvidia-smi/d' "$NODES_PM_FILE"
    fi
    
    # Find the latest pvemanagerlib.js backup
    local latest_pvemanagerlibjs
    latest_pvemanagerlibjs=$(find "$BACKUP_DIR" -name "nvidia-gpu.pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')
    
    if [[ -n "$latest_pvemanagerlibjs" ]]; then
        msgb "Restoring pvemanagerlib.js from backup: $latest_pvemanagerlibjs"
        cp "$latest_pvemanagerlibjs" "$PVE_MANAGER_LIB_JS_FILE"
        info "Restored pvemanagerlib.js successfully."
    else
        warn "No pvemanagerlib.js backup found. Manual restoration may be required."
        warn "You can reinstall pve-manager package to restore: apt install --reinstall pve-manager"
    fi
    
    restart_proxy
    
    info "Uninstallation completed."
    msgb "\nIMPORTANT: Clear your browser cache (Ctrl+Shift+R) to see the changes."
}

# Process command line arguments
executed=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        install)
            executed=$((executed + 1))
            install_mod
            ;;
        uninstall)
            executed=$((executed + 1))
            uninstall_mod
            ;;
        *)
            warn "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

# If no arguments provided, show usage
if [[ $executed -eq 0 ]]; then
    usage
fi
