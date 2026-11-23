#!/bin/zsh
# Removes Pie in the Sky: quits the app, deletes it and the audio driver, restarts coreaudiod.
# The app's menu has the same action ("Uninstall…"); use this if the app is already gone.
osascript -e 'quit app "Pie in the Sky"' 2>/dev/null
rm -rf "/Applications/Pie in the Sky.app"
sudo rm -rf /Library/Audio/Plug-Ins/HAL/PieInTheSky.driver
sudo killall coreaudiod
echo "Pie in the Sky removed."
