#!/bin/bash
# This script updates all running Proxmox containers, skipping specified excluded containers, and generates a separate log file for each container.
# The script first updates the Proxmox host system, then iterates through each container, updates the container, and reboots it if necessary.
# Each container's log file is stored in $log_path and the main script log file is named container-upgrade-main.log.

# Path where logs are saved
log_path="/root/scripts"

# array of container ids to exclude from updates
exclude_containers=("106")

# path to programs
pct="/usr/sbin/pct"

# list of container ids we need to iterate through
containers=$($pct list | tail -n +2 | cut -f1 -d' ')

#### CODE BELOW #########
container_main_log_file="${log_path}/container-upgrade-main.log"

echo "[Info] Updating proxmox containers at $(date)" 
echo "[Info] Updating proxmox containers at $(date)" >> $container_main_log_file

#function to update individual containers
function update_container() {
  container=$1
  # log file for individual container
  container_log_file="${log_path}/container-upgrade-$container.log"
  
  # log start of update
  echo "[Info] Starting update for container $container at $(date)" >> $container_log_file
  
  # perform the update
  $pct exec $container -- bash -c "apt update && apt upgrade -y && apt autoremove -y && reboot" >> $container_log_file 2>&1
  
  # log completion of update
  echo "[Info] Completed update for $container at $(date)" >> $container_log_file
  echo "--------------------------------------------------------------------------------------------" >> $container_log_file
}

for container in $containers; do
  # skip excluded containers
  if [[ " ${exclude_containers[@]} " =~ " ${container} " ]]; then
    echo "[Info] Skipping excluded container, $container"
    echo "[Info] Skipping excluded container, $container" >> $container_main_log_file
    continue
  fi
  
  status=$($pct status $container)
  if [ "$status" == "status: stopped" ]; then
    echo "[Info] Skipping offline container, $container"
    echo "[Info] Skipping offline container, $container" >> $container_main_log_file
  elif [ "$status" == "status: running" ]; then
    update_container $container
  fi
done; wait

# log completion of all updates
echo "[Info] Updating proxmox containers completed at $(date)" 
echo "[Info] Updating proxmox containers completed at $(date)" >> $container_main_log_file
echo "--------------------------------------------------------------------------------------------" >> $container_main_log_file