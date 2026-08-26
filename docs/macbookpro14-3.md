# MacBookPro14,3 field notes (Omarchy)

Verified 2026-08-25 on a **MacBookPro14,3** (15-inch 2017, Touch Bar) dual-booting
macOS and Omarchy 4.0.1, kernel **7.1.9-arch1-2**, gcc 16.2.1.

The 13-inch 14,2 recipe in the root README is the one to follow. This page is
only the 15-inch deltas.

## Hardware

| | 14,3 |
| --- | --- |
| T1 / iBridge | `05ac:8600` (must not be `1281`) |
| Wi-Fi | Broadcom BCM43602 (`brcmfmac`) |
| Bluetooth | UART BCM20703A2 (`hci_uart`, ROM is enough) |
| GPU | Radeon Pro 560 (`amdgpu`) + Intel HD 630 (`i915`) via `apple_gmux` |
| Audio | Cirrus CS8409 (`davidjo/snd_hda_macbookpro`) |
| Panel | `amdgpu` drives `eDP-1`; Intel stays runtime-suspended |

Same T1 as 14,2. Same iBridge HID pair. Same two Touch Bar bugs.

## What was confirmed working

- Touch Bar: Esc + F1–F12, `fnmode=0`, persists via `touchbar.service`
- Wi-Fi 5 GHz after NVRAM in `/usr/lib/firmware/updates/brcm/` (survives
  `linux-firmware` upgrades; `/lib/firmware/brcm/` does not)
- Speakers + internal mic after CS8409 DKMS
- Suspend, NVMe `d3cold_allowed=0`, USB-C after `pcie_ports=compat`
- Keyboard / trackpad via mainline `applespi`
- Webcam (UVC, once T1 firmware is intact)

Do **not** install T2 packages (`tiny-dfr`, `linux-t2`). This is a T1.

## Touch Bar

Same sequence as [`drivers/appleibridge/WORKING-RECIPE.md`](../drivers/appleibridge/WORKING-RECIPE.md).

Two packaging mismatches that broke a first 14,3 install, now fixed in-tree:

1. `dkms.conf` used `DEST_MODULE_LOCATION=/updates` and `REMAKE_INITRD=yes`,
   while `touchbar-enable.sh` looked only in `updates/dkms`. Arch DKMS 3.4
   then either hid the `.ko` from the service or rebuilt initramfs — both
   wrong. Dest is now `/updates/dkms`, initramfs rebuild is off, and the
   enable script searches `updates/dkms`, `updates`, and `extra`.
2. `hid-sensor-hub` still steals `0003:05AC:8600.0002`. The late oneshot
   unbinds it. Never load these modules from `modules-load.d`.

`apple_ib_als` builds but is not loaded. ALS is on the iBridge; it does not
dim the Touch Bar. The strip stays lit because `idle_timeout=-1` and
`dim_timeout=-1`. Screen idle is a separate Omarchy timer.

The T1 driver can only show canned layouts (Esc+F-keys or media keys). It
cannot draw a macOS Control Strip / Siri button. That needs the iBridge
display USB config, which this recipe deliberately avoids.

## Escape before the Touch Bar is up

There is no physical Esc on a Touch Bar Mac. Until the driver lights the
strip, map Fn + `` ` `` with [keyd](https://github.com/rvaiya/keyd):

```
# /etc/keyd/apple-esc.conf
[ids]
*

[main]
fn = layer(fn)

[fn]
grave = esc
```

`fn+grave` as a *chord* (simultaneous within 50 ms) still prints backtick.
Fn as a layer is what actually works. After the Touch Bar is up, Esc on the
strip is a real `KEY_ESC`; keep the keyd map as a fallback.

## Wi-Fi NVRAM

Place the file under **`/usr/lib/firmware/updates/brcm/brcmfmac43602-pcie.txt`**,
not `/lib/firmware/brcm/`. Omarchy / pacman own the latter.

The 14,3 board came up on 5 GHz with the in-tree dump (`boardflags3=0x00000300`).
A live `rmmod brcmfmac` after a bad NVRAM wedged the chip — only a full
power-off recovered it. Do not reload the driver live. Reboot, with a
failsafe if Wi-Fi is the only route in.

## Audio

`davidjo/snd_hda_macbookpro` DKMS, quirk `0x106b3900` / `CS8409_MBP143`.
The internal mic ships muted; unmute in WirePlumber/PipeWire. Capture level
is low by design.

## Bluetooth

`hci0` comes up from ROM. Apple's `BCM20703-MiniDriver-uart.hex` on the macOS
volume is an ARM MiniDriver, **not** a Linux HCI PatchRAM `.hcd`. Do not drop
a guessed `BCM.hcd` into `/lib/firmware/brcm/` — that can take UART Bluetooth
offline.

## Dual GPU

`amdgpu` drives the internal panel. `i915` remains present and typically
runtime-suspended. No extra hybrid-GPU switching was required on this machine.

## Contribute

This tree is meant to land as PRs on
[nohzafk/omarchy-macbookpro-t1](https://github.com/nohzafk/omarchy-macbookpro-t1).
14,3-only notes belong in this file so the 14,2 recipe stays the default path.
