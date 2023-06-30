#!/bin/bash
#This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) to display temperature information.

# Filepaths
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
nodespm="/usr/share/perl5/PVE/API2/Nodes.pm"
backupLocation="/root/backup"

# Sensor configuration
# CPU. See tempN_in put for "Core 0" using sensor -j
cpuTempInputOffset="2";

# Display configuration for HDD, NVME, CPU
cpuPerRow="4";
hddPerRow="4";
nvmePerRow="4";

# Known CPU sensor names. If new are added, also update logic in configure section
knownCpuSensors=("coretemp-isa-0000" "k10temp-pci-00c3")

################### code below #############
timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

echo ""

# Function to display usage information
function usage {
  echo "Usage: $0 [install | uninstall]"
  echo ""
  exit 1
}

# Define a function to install packages
install_packages () {
  # Check if the 'sensors' command is available on the system
  if (! command -v sensors &> /dev/null); then
    # If the 'sensors' command is not available, prompt the user to install lm-sensors
    read -p "lm-sensors is not installed. Would you like to install it? (y/n) " choice
    case "$choice" in
      y|Y )
        # If the user chooses to install lm-sensors, update the package list and install the package
        apt-get update
        apt-get install lm-sensors
        ;;
      n|N )
        # If the user chooses not to install lm-sensors, exit the script with a zero status code
        echo "Decided to not install lm-sensors. The mod cannot run without"
        exit 0
        ;;
      * )
        # If the user enters an invalid input, print an error message and exit the script with a non-zero status code
        echo "Invalid input. Exiting..."
        exit 1
        ;;
    esac
  fi

  # Check if kernal module drivetemp is installed
  if (lsmod | grep -wq "drivetemp"); then
    echo "The drivetemp kernel module is installed."
  else
    echo "Warning: The drivetemp kernel module is not installed. HDD temps will not be available"
  fi
}

function configure {
   
  sensorOutput=$(sensors -j)

  # Check if kernal module drivetemp is installed
  if (lsmod | grep -wq "drivetemp"); then
      # Check if SDD/HDD data is available
      if (echo "$sensorOutput" | grep -q "drivetemp-scsi-" ); then
        echo "Found SSD/HDD temp sensor: $(echo "$sensorOutput" | grep -o '"drivetemp-scsi[^"]*"'| sed 's/"//g')"
        enableHddSsdTemp=true
      else
        enableHddSsdTemp=false
      fi
  else
    enableHddSsdTemp=false
  fi

  # Check if NVME data is available
   if (echo "$sensorOutput" | grep -q "nvme-" ); then
     echo "Found nvme temp sensor: $(echo "$sensorOutput" | grep -o '"nvme[^"]*"'| sed 's/"//g')"
     enableNvmeTemp=true
   else
     enableNvmeTemp=false
   fi

   # Check if CPU is part of known list for autoconfiguration
   for item in "${knownCpuSensors[@]}"; do
       case "$sensorOutput" in
        *"coretemp-isa-0000"*)
          echo "Found known cpu sensor: coretemp-isa-0000"
          cpuAddress="coretemp-isa-0000"
          cpuItemPrefix="Core"
          break
          ;;
        *"k10temp-pci-00c3"*)
          echo "Found known cpu sensor: k10temp-pci-00c3"
          cpuAddress="k10temp-pci-00c3"
          cpuItemPrefix="Tccd"
          break
          ;;
        *)
          continue
          ;;
      esac
   done

   # If cpu is not known, ask the user for input
   if [ -z "$cpuItemPrefix" ]; then
      echo "Warning: Could not automatically determine CPU sensor. Please configure it manually."
      # Ask user for CPU information
      # Inform the user and prompt them to press any key to continue
      read -rsp $'Sensor output will be presented. Press any key to continue...\n' -n1 key

      # Print the output to the user
      echo "Sensor Output:"
      echo "$sensorOutput"

      echo "Example: cpu address: coretemp-isa-0000 and cpuItemPrefix Core."

      # Prompt the user for adapter name and item name
      read -p "Enter the cpu address: " cpuAddress
      read -p "Enter the cpu item prefix: " cpuItemPrefix
   fi
   
   if [[ -z "$cpuItemPrefix" || -z "$cpuItemPrefix" ]]; then
    echo "Warning: The cpu configuration is not set. Temps will not be available"
   fi
}

# Function to install the modification
function install_mod {
  # Create backup of original files
  mkdir -p "$backupLocation"

  # Add new line to Nodes.pm file
  if [[ -z $(cat $nodespm | grep -e "$res->{thermalstate}") ]]; then
    # Create backup of original file
    cp "$nodespm" "$backupLocation/Nodes.pm.$timestamp"
    echo "Backup of \"$nodespm\" saved to \"$backupLocation/Nodes.pm.$timestamp\""

    sed -i '/my $dinfo = df('\''\/'\'', 1);/i\'$'\t''$res->{thermalstate} = `sensors -j`;\n' "$nodespm"
    echo "Added thermalstate to $nodespm"
  else
    echo "Thermalstate already added to $nodespm"
  fi

  # Add new item to the items array in PVE.node.StatusView
  if [[ -z $(cat "$pvemanagerlib" | grep -e "itemId: 'thermal'") ]]; then
    # Create backup of original file
    cp "$pvemanagerlib" "$backupLocation/pvemanagerlib.js.$timestamp"
    echo "Backup of \"$pvemanagerlib\" saved to \"$backupLocation/pvemanagerlib.js.$timestamp\""

    # Expand space in StatusView
    sed -i "/Ext.define('PVE\.node\.StatusView'/,/\},/ {
      s/\(bodyPadding:\) '[^']*'/\1 '20 15 20 15'/
      s/height: [0-9]\+/minHeight: 360,\n\tflex: 1/
      s/\(tableAttrs:.*$\)/trAttrs: \{ valign: 'top' \},\n\t\1/}" "$pvemanagerlib"

    echo "Expanded space in \"$pvemanagerlib\""

    sed -i "/^Ext.define('PVE.node.StatusView',/ {
      :a;
      /items:/!{N;ba;}
      :b;
      /swap.*},/!{N;bb;}
      a\
      \\
        {\n\
            itemId: 'thermal',\n\
            colspan: 1,\n\
            printBar: false,\n\
            title: gettext('CPU Thermal State'),\n\
            iconCls: 'fa fa-fw fa-thermometer-half',\n\
            textField: 'thermalstate',\n\
            renderer: function(value){\n\
            // sensors configuration\n\
            const cpuAddress = \"$cpu_address\";\n\
            const cpuItemPrefix = \"$cpu_item_prefix\";\n\
            // display configuration\n\
            const coresPerRow = $cpuPerRow;\n\\n\
            const objValue = JSON.parse(value);\n\
            if(objValue.hasOwnProperty(cpuAddress)) \{\n\
            	items = objValue[cpuAddress],\n\
                coreKeys = Object.keys(items).filter(item => \{ return String(item).includes(cpuItemPrefix); \}).sort();\n\\n\
                let temps = [];\n\
                coreKeys.forEach((coreKey, index) => \{\n\
                    try \{\n\
                        Object.keys(items[coreKey]).forEach((secondLevelKey) => {\n\
                            if (secondLevelKey.includes('_input')) {\n\
                                let temp = items[coreKey][secondLevelKey];\n\
                                temps.push(\`Core \$\{index\}: \$\{temp\}&deg;C\`);\n\
                            }\n\
                        })\n\
                    \} catch(e) \{ /*_*/ \}\n\
                  });\n\\n\
            	const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % coresPerRow === 0 ? '<br>' : ' | ') : '')});\n\
                return result.length > 0 ? result.join('') : 'N/A';\n\
              \}\n\
            }\n\
        },
    }" "$pvemanagerlib"

    if [ $enableNvmeTemp = true ]; then
        sed -i "/^Ext.define('PVE.node.StatusView',/ {
          :a;
          /items:/!{N;ba;}
          :b;
          /thermal.*},/!{N;bb;}
          a\
          \\
        {\n\
            itemId: 'thermal2',\n\
            colspan: 1,\n\
            printBar: false,\n\
            title: gettext('NVME Thermal State'),\n\
            iconCls: 'fa fa-fw fa-thermometer-half',\n\
            textField: 'thermalstate',\n\
            renderer: function(value) {\n\
            // sensors configuration\n\
            const addressPrefix = \"nvme-pci-\";\n\
            const sensorName = \"Composite\";\n\
            // display configuration\n\
            const drivesPerRow = ${nvmePerRow};\n\
            const objValue = JSON.parse(value);\n\
            nvmeKeys = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();\n\
            let temps = [];\n\
            nvmeKeys.forEach((nvmeKey, index) => {\n\
                try {\n\
                    Object.keys(objValue[nvmeKey][sensorName]).forEach((secondLevelKey) => {\n\
                        if (secondLevelKey.includes('_input')) {\n\
                            let temp = objValue[nvmeKey][sensorName][secondLevelKey];\n\
                            temps.push(\`Drive \$\{index\}: \$\{temp\}&deg;C\`);\n\
                        }\n\
                    })\n\
                } catch(e) { /*_*/ }\n\
            });\n\
            const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % drivesPerRow === 0 ? '<br>' : ' | ') : ''); });\n\
            return result.length > 0 ? result.join('') : 'N/A';\n\
            \}\n\
        },
        }" "$pvemanagerlib"
    fi

    if [ $enableHddSsdTemp = true ]; then
        sed -i "/^Ext.define('PVE.node.StatusView',/ {
          :a;
          /items:/!{N;ba;}
          :b;
          /thermal2.*},/!{N;bb;}
          a\
          \\
        {\n\
            xtype: 'box',\n\
            colspan: 1,\n\
            padding: '0 0 20 0',\n\
        },\n\
        {\n\
            itemId: 'thermal3',\n\
            colspan: 1,\n\
            printBar: false,\n\
            title: gettext('HDD/SSD Thermal State'),\n\
            iconCls: 'fa fa-fw fa-thermometer-half',\n\
            textField: 'thermalstate',\n\
            renderer: function(value) {\n\
            // sensors configuration\n\
            const addressPrefix = \"drivetemp-scsi-\";\n\
            const sensorName = \"temp1\";\n\
            // display configuration\n\
            const drivesPerRow = ${hddPerRow};\n\
            const objValue = JSON.parse(value);\n\
            drvKeys  = Object.keys(objValue).filter(item => String(item).startsWith(addressPrefix)).sort();\n\
            let temps = [];\n\
            drvKeys .forEach((drvKey, index) => {\n\
                try {\n\
                    Object.keys(objValue[drvKey][sensorName]).forEach((secondLevelKey) => {\n\
                        if (secondLevelKey.includes('_input')) {\n\
                            let temp = objValue[drvKey][sensorName][secondLevelKey];\n\
                            temps.push(\`Drive \$\{index\}: \$\{temp\}&deg;C\`);\n\
                        }\n\
                    })\n\
                } catch(e) { /*_*/ }\n\
            });\n\
            const result = temps.map((strTemp, index, arr) => { return strTemp + (index + 1 < arr.length ? ((index + 1) % drivesPerRow === 0 ? '<br>' : ' | ') : ''); });\n\
            return result.length > 0 ? result.join('') : 'N/A';\n\
            \}\n\
        },
        }" "$pvemanagerlib"
    fi

    echo "Added new item to the items array in \"$pvemanagerlib\""
  else
    echo "New item already added to items array \"$pvemanagerlib\""
  fi

  # Restart pveproxy
  systemctl restart pveproxy
}

# Function to uninstall the modification
function uninstall_mod {
  # Find the latest Nodes.pm file using the find command
  latest_Nodes_pm=$(find "$backupLocation" -name "Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

  if [ -z "$latest_Nodes_pm" ]; then
    echo "No Nodes.pm files found"
    exit 1
  fi

  # Remove the latest Nodes.pm file
  cp "$latest_Nodes_pm" "$nodespm"
  echo "Copied latest backup to $nodespm"

  # Find the latest pvemanagerlib file using the find command
  latest_pvemanagerlib_js=$(find "$backupLocation" -name "pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

  if [ -z "$latest_pvemanagerlib_js" ]; then
    echo "No pvemanagerlib.js files found"
    exit 1
  fi

  # Remove the latest Nodes.pm file
  cp "$latest_pvemanagerlib_js" "$pvemanagerlib"
  echo "Copied latest backup to \"$pvemanagerlib\""

  # Restart pveproxy
  systemctl restart pveproxy
}

# If no arguments were provided or all arguments have been processed, print the usage message
if [[ $# -eq 0 ]]; then
    usage
fi

# Process the arguments using a while loop and a case statement
while [[ $# -gt 0 ]]; do
  case "$1" in
    install)
      echo "Installing the proxmox temp mod..."
      install_packages
      configure
      install_mod
      ;;
    uninstall)
      echo "Uninstalling the proxmox temp mod..."
      uninstall_mod
      ;;
    *)
      usage
      ;;
  esac
  shift
done

echo ""
exit 0