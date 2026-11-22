#!/bin/zsh
# Removes BT Latency Proxy: quits the app, deletes it and the audio driver, restarts coreaudiod.
# The app's menu has the same action ("Uninstall…"); use this if the app is already gone.
osascript -e 'quit app "BT Latency Proxy"' 2>/dev/null
rm -rf "/Applications/BT Latency Proxy.app"
sudo rm -rf /Library/Audio/Plug-Ins/HAL/BTLatencyProxy.driver
sudo killall coreaudiod
echo "BT Latency Proxy removed."
