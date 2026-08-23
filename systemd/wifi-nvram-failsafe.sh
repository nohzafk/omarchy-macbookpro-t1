#!/bin/bash
# Revert the BCM43602 NVRAM if the boot that first uses it fails to bring the network up.
#
# WHY THIS EXISTS
#   Installing /lib/firmware/brcm/brcmfmac43602-pcie.txt only takes effect on a fresh boot.
#   NetworkManager holds brcmfmac, so `modprobe -r brcmfmac` returns "Module brcmfmac is in
#   use" and the NVRAM is never re-read. On these machines Wi-Fi is often the only route in,
#   which makes a bad NVRAM a lockout rather than an inconvenience.
#
#   So: wait for NetworkManager to settle, and if the network did not come up, delete the
#   NVRAM and reboot into the known-good state. The cost of a false positive is one extra
#   reboot; the cost of no failsafe is a machine you cannot reach.
#
# DISABLE IT ONCE THE NVRAM IS CONFIRMED GOOD
#   sudo systemctl disable --now wifi-nvram-failsafe.service
#   Left armed, a future boot with a slow NetworkManager will false-positive and delete a
#   working file.
set -uo pipefail

NVRAM=/lib/firmware/brcm/brcmfmac43602-pcie.txt
SETTLE=${SETTLE:-100}

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

log "waiting ${SETTLE}s for NetworkManager to settle"
sleep "$SETTLE"

# `connected (site only)` and `connected (local only)` still mean the radio associated,
# which is what this is testing. Match the prefix, not the whole string.
state=$(nmcli -t -f STATE general 2>/dev/null)

if printf '%s' "$state" | grep -q '^connected'; then
  log "network up (state=${state:-unknown}) - NVRAM is good, leaving it in place"
  log "now disable this unit: systemctl disable --now wifi-nvram-failsafe.service"
  exit 0
fi

log "network DOWN (state=${state:-unknown}) - removing ${NVRAM} and rebooting"
rm -f "$NVRAM"
systemctl reboot
