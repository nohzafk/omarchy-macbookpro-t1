# appleibridge — Touch Bar driver for the Apple T1

Source for the iBridge Touch Bar and ambient light sensor drivers, with two local fixes.

**Upstream:** [`F13-Kr1pt0n/macbook-pro-touchbar-driver`](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver),
branch `touchbar-driver-hid-driver`, commit `ecfadc3` (2025-09-02).

That fork is the most current lineage by five years. The alternatives are all older and none
of them compile on a modern kernel:

| Repo | Last commit |
| --- | --- |
| `t2linux/apple-ib-drv` master | 2018-03-14 |
| `t2linux/apple-ib-drv` ibridge-reviews | 2019-07-19 |
| `kekrby/apple-ibridge` | 2021-09-20 |
| **`F13-Kr1pt0n`** | **2025-09-02** |

It ships no `applespi.c`, which is correct — that driver is mainline since 5.3, so the
keyboard and trackpad work without any of this.

## Fix 1 — `struct tb_touch` defined after it is used

`apple-ib-tb.c`

```
apple-ib-tb.c:174:31: error: field 'touch' has incomplete type
  174 |         struct tb_touch       touch;
```

`struct appletb_device` embeds `struct tb_touch` **by value**, but upstream defines that
struct about 30 lines later. C requires the definition first, so upstream's own
`LINUX_VERSION_CODE >= KERNEL_VERSION(6,15,0)` path has never compiled on any kernel. Not a
kernel-API problem — a plain ordering bug.

Fix: move the definition above `struct appletb_device`, unchanged.

## Fix 2 — synchronous configuration change from probe

`apple-ibridge.c`. `apple_ib_set_tb_mode()` is called from `appleib_hid_probe()`, but it used
the synchronous `usb_set_configuration()` helper. Changing configuration destroys the HID
interface that is currently being probed and creates replacement interfaces.

```
INFO: task modprobe:24033 blocked for more than 983 seconds.
INFO: task modprobe:24033 is blocked on a mutex likely owned by task modprobe:24033.
```

Dropping `appleib_tbmode_lock` and adding a re-entrancy guard avoids that first self-deadlock,
but it is not sufficient. A later trace showed the probing `udev-worker` blocked in
`device_del()` while synchronously tearing down its own interface:

```
task:(udev-worker) state:D
  device_del
  hid_destroy_device
  usbhid_disconnect
  usb_set_configuration
  apple_ib_set_tb_mode
  appleib_hid_probe
```

The stuck worker cannot be frozen, so every suspend attempt times out even when the machine
otherwise remains usable.

Fix: use `usb_driver_set_configuration()`. USB core documents this helper specifically for
the rare case where an interface driver must change configurations. It retains the device
reference and performs `usb_set_configuration()` on a work thread after the probe path can
release its device-model locks.

The replacement HID interfaces probe only after the queued configuration switch starts; by
then the requested configuration is active and `apple_ib_set_tb_mode()` takes its no-op path.

## A zero-code workaround, worth knowing

The deadlock only fires when the driver actually *changes* USB configuration. It does not
if the requested mode already matches the current one:

```c
if (udev->actconfig && udev->actconfig->desc.bConfigurationValue == target_cv) {
        ret = 0;
        goto out_unlock;          /* usb_set_configuration() never called */
}
```

On this machine the iBridge boots in configuration 1, which contains the HID interfaces —
the driver's definition of the *keyboard* config:

```
bNumConfigurations: 3      current: 1
  1-3:1.0  class=0x0e  uvcvideo    webcam
  1-3:1.1  class=0x0e  uvcvideo    webcam
  1-3:1.2  class=0x03  usbhid      HID  -> "keyboard" config
  1-3:1.3  class=0x03  usbhid
```

`appleib_cfg_is_keyboard()` matches `USB_CLASS_HID`, `appleib_cfg_is_display()` matches
`USB_CLASS_VENDOR_SPEC`, and the default `AUTO` **prefers display** — so it tries to switch
away from config 1 and deadlocks. Loading with

```
apple_ibridge.tb_mode_param=keyboard
```

selects the config the device is already in, takes the early return, and never deadlocks
even on unpatched code. Keyboard mode is also the useful one: Esc and F1-F12.

## Build

```bash
sudo pacman -S --needed linux-headers dkms
sudo mkdir -p /usr/src/appleibridge-0.1
sudo cp apple-ib-als.c apple-ib-tb.c apple-ibridge.c apple-ibridge.h \
        Makefile dkms.conf /usr/src/appleibridge-0.1/
sudo dkms add     -m appleibridge -v 0.1
sudo dkms build   -m appleibridge -v 0.1
sudo dkms install -m appleibridge -v 0.1
```

Verified building on **7.1.8-arch1-3** with **gcc 16.2.1**.

## Load it safely

**Never put these in `/etc/modules-load.d/` while testing.** If a module wedges at boot it
hangs `sysinit.target`, the login screen never appears, and the only way out is a forced
power-off. Load by hand so a failure costs one reboot instead of your boot.

The blacklist in `/etc/limine-entry-tool.d/macbookpro14-2.conf` stops `modprobe` from
loading them at all, which is deliberate. To test without removing it, use `insmod` on the
decompressed modules — `insmod` ignores modprobe's blacklist.

Order matters: `apple_ibridge` first, it is the coordinator.

```bash
lsmod | grep -E '^apple_ib'                       # expect nothing
dmesg -w &                                        # watch it
sudo insmod apple-ibridge.ko tb_mode_param=keyboard
sudo insmod apple-ib-tb.ko
```

Working means the Touch Bar lights up with Esc and function keys. A hang means the module is
wedged in `D` state; the system stays usable over SSH but shutdown will hang, so plan on a
power-button hold.
