# Firmware artifacts

## `brcmfmac43602-pcie.txt` — the NVRAM that fixes Wi-Fi

This is the single most valuable file in this repo after the ESP backups. It turned a
crippled Wi-Fi adapter into a working one.

### What it fixes

Without it, `brcmfmac` brings the BCM43602 up with no board configuration at all:

| | Without NVRAM | With NVRAM |
| --- | --- | --- |
| MAC address | `00:90:4c:xx:xx:xx` — Broadcom's generic placeholder | the real Apple MAC |
| Bands | `Band 1` only, 2.4 GHz | `Band 1` **and** `Band 2` |
| Signal at the same spot | **-74 dBm** | **-42 dBm** |
| Link rate | 2.4 GHz rates | **324 Mbit/s** |
| Reliability | `scp` failed 4 times in a row | stable |

The 26 dB signal improvement is the part most write-ups miss. Everyone frames this as "no
5 GHz on BCM43602", but the file also carries the **TX power tables and RF calibration
data**. Running without it leaves the radio on generic defaults, so the adapter is both
band-limited *and* deaf. Fixing the NVRAM fixes both at once.

The placeholder MAC is the tell. If `ip link` shows a `00:90:4C:...` address — Broadcom's
OUI — no NVRAM was loaded, and everything above applies.

### Install

```bash
# 1. set your own MAC. Read it from macOS (System Information > Wi-Fi), because under
#    Linux without NVRAM the adapter reports the placeholder, not the real one.
sed -i 's/^macaddr=.*/macaddr=AA:BB:CC:DD:EE:FF/' brcmfmac43602-pcie.txt   # <- YOUR MAC

# 2. install under firmware/updates so a linux-firmware package upgrade
#    cannot clobber it. /lib/firmware/brcm/ is owned by the package.
sudo mkdir -p /usr/lib/firmware/updates/brcm
sudo cp brcmfmac43602-pcie.txt /usr/lib/firmware/updates/brcm/brcmfmac43602-pcie.txt

# 3. reboot. The driver cannot be reloaded live — NetworkManager holds it, so
#    `modprobe -r brcmfmac` fails with "Module brcmfmac is in use" and the NVRAM is
#    never re-read. Only a fresh boot picks it up.
sudo reboot
```

Verify:

```bash
cat /sys/class/net/wlp2s0/address   # should be your real MAC, not 00:90:4c:...
iw phy | grep Band                  # should list Band 1 AND Band 2
iw dev wlp2s0 link                  # freq should be able to sit in the 5xxx range
```

### Install it safely

Wi-Fi may be the only route into the machine, so a bad NVRAM can lock you out. Arm a
failsafe **before** rebooting: a `systemd` oneshot that waits ~100 s after boot, checks
`nmcli -t -f STATE general`, and deletes the NVRAM plus reloads `brcmfmac` if the network
did not come up. Disable it once the change is confirmed good — otherwise a future boot
with a slow NetworkManager will false-positive and delete a working file.

### Provenance and caveats

Sourced from [MikeRatcliffe's gist](https://gist.github.com/MikeRatcliffe/9614c16a8ea09731a9d5e91685bd8c80),
a real dump from Apple BCM43602 hardware. Used **unmodified except for the MAC**.

- `devid=0x43ba` matches this chip exactly.
- `boardtype=0x61b`, `boardrev=0x1421` are board-specific and could not be verified
  against a `MacBookPro14,2`. They work anyway.
- `aa2g=7 aa5g=7 txchain=7 rxchain=7` implies three antennas, which suggests the dump came
  from a 15-inch board. It still works on this 13-inch machine.
- `boardflags3=0x00000300`. Several guides insist `0xC0000303` is required to enable both
  bands. **That was not necessary here** — 5 GHz came up with the value above. If 5 GHz
  does not appear for you, that is the next single variable to change.
- `ccode=00` and `regrev=245` were left as-is. The kernel's own regulatory domain still
  applies, so channel legality is enforced regardless.

The MAC in the copy stored here is deliberately `xx:xx:xx:xx:xx:xx`. Set your own.
