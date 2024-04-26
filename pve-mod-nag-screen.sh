#!/usr/bin/env bash
#
# This bash script installs a modification to the Proxmox Virtual Environment (PVE) web user interface (UI) which deactivates the subscription nag screen.
#

################### Configuration #############

# This script's working directory
SCRIPT_CWD="$(dirname "$(readlink -f "$0")")"

# Files backup location
BACKUP_DIR="$SCRIPT_CWD/backup"

# File paths
proxmoxlibjs="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
proxmoxlibminjs="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.min.js"

###############################################

# Helper functions
function msg {
	echo  -e "\e[0m$1\e[0m"
}

#echo message in bold
function msgb {
	echo -e "\e[1m$1\e[0m"
}

function warn {
	echo  -e "\e[0;33m[warning] $1\e[0m"
}

function err {
	echo  -e "\e[0;31m[error] $1\e[0m"
	exit  1
}
# End of helper functions

# Function to display usage information
function usage {
	msgb "\nUsage:\n$0 [install | uninstall]\n"
	exit 1
}

function restart_proxy {
	# Restart pveproxy
	msg "\nRestarting PVE proxy..."
	systemctl restart pveproxy
}

function install_mod {
	msg "\nPreparing mod installation..."

	local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
	local restart=false

	if (! grep -q "// disable subscription nag screen" "$proxmoxlibjs"); then
		if [ -f "$proxmoxlibjs" ]; then
			mkdir -p "$BACKUP_DIR" || err "Error creating backup directory."

			# Create backup of original file
			msg "Saving current version of \"$proxmoxlibjs\" to \"$BACKUP_DIR/proxmoxlib.js.$timestamp\"."
			cp -P "$proxmoxlibjs" "$BACKUP_DIR/proxmoxlib.js.$timestamp" || err "Error creating backup."

			msg "Deactivating the nag screen..."
			sed -i "/Ext.define('Proxmox.Utils',/ {
				:a;
				/checked_command:\s*function(orig_cmd)\s*{/!{N;ba;}
				a\
				\\
	// disable subscription nag screen\n\
	orig_cmd();\n\
	return;
			}" "$proxmoxlibjs"
		fi
		restart=true
	else
		warn "Nag screen already deactivated."
	fi

	if [ ! -h "$proxmoxlibminjs" ]; then
		msg "Disabling minified front-end library file..."
		(mv "$proxmoxlibminjs" "$BACKUP_DIR/proxmoxlib.min.js.$timestamp" &&
			ln -s "$proxmoxlibjs" "$proxmoxlibminjs") || err "Error disabling minified front-end library file."
		restart=true
	else
		warn "Minified front-end library file already disabled."
	fi

	if [ $restart = true ]; then
		restart_proxy
	fi
}

function uninstall_mod {
	msg "\nRestoring modified files..."

	local restart=false

	# Find the latest backup file of proxmoxlib.js
	local latest_proxmoxlibjs=$(find "$BACKUP_DIR" -name "proxmoxlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -z "$latest_proxmoxlibjs" ]; then
		warn "No proxmoxlib.js backup files found."
	else
		# Remove the latest proxmoxlib.js file
		msg "Restoring \"$proxmoxlibjs\" from the latest backup file."
		cp "$latest_proxmoxlibjs" "$proxmoxlibjs"
		restart=true
	fi

	local latest_proxmoxlibminjs=$(find "$BACKUP_DIR" -name "proxmoxlib.min.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

	if [ -z "$latest_proxmoxlibminjs" ]; then
		warn "No proxmoxlib.min.js backup files found."
	else
		# Remove the latest proxmoxlib.min.js file
		msg "Restoring \"$proxmoxlibminjs\" from the latest backup file."
		rm "$proxmoxlibminjs" && cp "$latest_proxmoxlibminjs" "$proxmoxlibminjs"
		restart=true
	fi

	if [ $restart = true ]; then
		restart_proxy
	fi
}

# Process the arguments using a while loop and a case statement
executed=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		install)
			executed=$(($executed + 1))
			msgb "\nInstalling the Proxmox VE nag screen mod..."
			install_mod
			echo # add a new line
			;;
		uninstall)
			executed=$(($executed + 1))
			msgb "\nUninstalling the Proxmox VE nag screen mod..."
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
