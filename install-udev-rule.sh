#!/bin/bash
# Installs the udev rule that grants access to the DJI receiver. Run with sudo or pkexec.
set -e
install -m 644 "$(dirname "$(readlink -f "$0")")/70-dji-mic.rules" /etc/udev/rules.d/70-dji-mic.rules
udevadm control --reload
udevadm trigger --subsystem-match=usb --attr-match=idVendor=2ca3 --action=change
