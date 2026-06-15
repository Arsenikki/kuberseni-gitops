#!/bin/bash

# Check if IP address is provided as a parameter
if [ -z "$1" ]; then
    echo "Error: No IP address provided."
    echo "Usage: ./debloat.sh <TV_IP_ADDRESS>"
    exit 1
fi

TV_IP="$1"
ADB_PORT=5555

# Connect to ADB over the network
echo "Connecting to TV at IP address: $TV_IP..."
adb connect "$TV_IP:$ADB_PORT"

# Check if the connection was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to connect to TV at IP address: $TV_IP"
    exit 1
fi

# Set max cached processes to 4
echo "Setting max cached processes to 4..."
adb shell /system/bin/device_config put activity_manager max_cached_processes 4

# Set max phantom processes to 8
echo "Setting max phantom processes to 8..."
adb shell /system/bin/device_config put activity_manager max_phantom_processes 8

adb shell /system/bin/device_config set_sync_disabled_for_tests persistent
