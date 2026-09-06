# Pico 3/4 Bootloader Unlock & Root Tool & Data Backup

<img height="300" alt="unlocked" src="./src/unlocked.jpg" /> <img height="300" alt="unlocked" src="./src/mainmenu.png" />

This repository contains a comprehensive set of tools and scripts to unlock the bootloader and root the **Pico 4** (confirmed), **Pico 4 Pro** (confirmed), and **Pico Neo 3** VR headsets.

### [Download Tool](https://github.com/chaixshot/more-picohaxx-tool/releases/latest), run `picounlock.bat` to begin

> [!CAUTION]
> **!!! DO A BACKUP FIRST !!!**
> It is highly recommended to perform a **userdata backup via EDL** before starting.
> Unlocking the bootloader **WILL WIPE ALL USER DATA**. Use the built-in **Backup/Restore** menu before proceeding.
>
## Backup & Restore

This tool includes a built-in **Backup/Restore** suite to protect your user data from factory reset.

### Backup Modes

1.  **Physical Binary Dump (LUNs)**
    *   Sector-by-sector clone of physical drives (LUN 0-6).
    *   Best for unbricking, GPT repair, and low-level recovery.
2.  **User Personal Data (UserData)**
    *   Backup of the `userdata` partition ONLY.
    *   Includes all apps, games, photos, and internal storage files.
3.  **System Partition Dump (Partitions)**
    *   Individual file per system partition (boot, abl, system, etc.).
    *   Best for general firmware backup or modding. Excludes userdata.

### Features

* **Easy Restoration**: Select between different backup sets using the menu.
* **Custom Backup Location**: Specify your own folder path when starting a backup to save space on your system drive or organize files manually.
* **Smart Restoration**: Paste a backup folder path directly into the menu. The script automatically detects the backup type (LUNs, UserData, or Partitions) based on the files inside.
* **Transparent LZX Compression**: Optional folder compression for backups using Windows native `compact.exe`. Reduces backup size by up to **60%** while keeping files directly accessible with negligible CPU impact.
* **EDL Integration**: Automates the complex EDL workflow using the provided `EDLHelper` (powered by `edl-ng`).

## Status

* **Pico 4**: Confirmed working.
* **Pico 4 Pro**: Confirmed working.
* **Pico Neo 3**: Not confirmed yet, but should work the same (uses ABL and devinfo from P3 firmware).

## Prerequisites

* **Windows PC**: The automation script is written in PowerShell.
* **PowerShell Execution**: If script can not run, follow [ps-enabling-exec-scripts](https://github.com/whonion/ps-enabling-exec-scripts) guide
* **Pico Device**: Pico 4, Pico 4 Pro, or Pico Neo 3 with [USB Debug](#usb-debug) enabled.

## WARNING

* **Risk**: Flashing firmware carries inherent risks. While this method is tested, you proceed at your own risk.
* **Engineering ABL & Devinfo**: The process involves flashing early engineering files. On Pico 4, this may result in SELinux being set to permissive.

## How It Works

1. **Perform Backup**: Choose a **User Personal Data** backup before proceeding, as unlocking will wipe the device.
1. **Get Chip ID**: Acquire your `serial_number` (Chip ID) via `adb` (from `/sys/devices/soc0/serial_number`).
1. **Generate Token**: Use `more-picohaxx.py` to generate your personal unlock command.
1. **Flash Engineering ABL**: Flash the old `abl` and `devinfo` via EDL.
    * **Firehose Selection**: Choose the correct firehose based on your device hardware:
        * **Pico 4 / Pico Neo 3**: Select **DDR 4** (Standard firehose).
        * **Pico 4 Pro**: Select **DDR 5** (Lite firehose).
1. **Fastboot Unlock**: Issue the generated command from **Generate Token**, followed by:
    * `fastboot flashing unlock_critical`
    * `fastboot flashing unlock`
    * `fastboot oem setenforce 0`
1. **Reboot Bootloader**: Check the status. If it isn't unlocked, **repeat the steps**. This is expected behavior; don't be afraid to try again.
1. **Facory Reset**: Perform a full factory reset via recovery clear residual user data.
1. **Flash Backup ABL**: Flash back your original stock abl image to restore boot capability.
1. **Restore Userdata**: Restore your previously backed-up userdata

## Rooting with Magisk

The tool includes an automated workflow to root your device:

1. **Install Magisk APK**: The script installs `Magisk4Pico.apk` to your device.
2. **Patch Boot Image**: You will be guided to download your current firmware, extract `boot.img`, and patch it using the Magisk app on the headset.
3. **Flash Patched Image**: The script pulls the patched image back to your PC and flashes it via `fastboot`.

## Troubleshooting & Tips

### Unlock Persistence

If `fastboot oem device-info` shows the device as locked after the first attempt, **repeat the unlock commands**. It is known that the unlock bits (written to protected RPMB storage) might not "stick" immediately.

### Slow Boot or Automatic EDL Boot

Using the engineering ABL can cause issues like slow boot times or the device unexpectedly entering EDL mode. To fix this:

1. **Unlock and Root** the device successfully first.
2. Use the **"Flash backup ABL"** option in the script menu. This restores your original `abl` partition.
3. Because the unlock state is stored in the **RPMB**, you will remain unlocked even with the original ABL.
4. **Note**: This will return SELinux to `Enforcing`. Use a Magisk module (like `selinux_permissive`) to maintain permissive mode if your setup requires it.

### USB Connectivity

* Use a high-quality USB-C cable.
* If EDL mode is unstable, try a **USB 2.0 port** or a USB 2.0 hub.

### USB Debug

1. Open PicoOS settings menu
1. Goto General > About
1. Tap **Software version** 7 times quickly until the **Developer** tab appears
1. Goto **Developer** tab and enable the **USB Debug** option

<img width="500" alt="usbdebug" src="https://knowledge.matts-digital.com/wp-content/uploads/2025/12/debogage-usb-pico-g3-plus-1.jpg" />

### Manual Boot

* Edl mode: Hold <kbd>Vol Up</kbd> + <kbd>Vol Down</kbd> + <kbd>Power</kbd>.
* Recovery mode: Hold <kbd>Vol Up</kbd> + <kbd>Power</kbd>.
* Fastboot mode: Hold  <kbd>Vol Down</kbd> + <kbd>Power</kbd>.

## Key Components

* `picounlock.bat`: A convenient wrapper to run the script with Administrator privileges.
* `picounlock.ps1`: The main automation script (PowerShell).
* `modules/`: Contains modularized logic for `utils`, `root`, and `backuprestore`.
* `more-picohaxx.py`: The core logic for deriving the unlock code from the device serial number.
* `devinfo`: Engineering partition data required for the bypass.
* `tools/`: Contains `adb`, `fastboot`, and `edl-ng` tools.
* `Magisk4Pico.apk`: Included for rooting the device after unlocking.

## Credits

* **[typlo](https://github.com/264312431)**: For finding this bypass method and the previous root exploit.
* **[Fallen Angel](https://github.com/FallenAngel-PP)**: Fearless testing and validation, Magisk4Pico.
* **[QFILHelper](https://github.com/Beliathal/QFILHelper)**: Guildline flashing manager.
* **[edl-ng](https://github.com/strongtz/edl-ng)**: Modern Qualcomm Emergency Download CLI.

---
*For more technical details on the bypass mechanism, refer to the comments in `more-picohaxx.py`.*
