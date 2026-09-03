# AirPods Volume Memory

A small, native macOS menu-bar utility that remembers the output volume for each pair of AirPods and restores it when they reconnect. It is intended to work around the macOS/Bluetooth behavior where AirPods occasionally return at an unexpected volume.

The app is fully offline. Remembered values and preferences stay in macOS `UserDefaults` on your Mac.

## Highlights

- Remembers a separate volume for each AirPods device using its persistent CoreAudio UID.
- Applies three bounded restore passes while Bluetooth audio settles, then verifies the result.
- Ignores temporary reconnect volume changes so they cannot overwrite the remembered value.
- Rebuilds audio listeners and restores again after the Mac wakes from sleep.
- Detects normally named AirPods, AirPods identified by their model, and renamed Apple Bluetooth headphones.
- Watches both master-volume and left/right channel controls.
- Preserves exact volume values set in Control Center; the menu slider follows the 16 keyboard-volume steps.
- Provides a Device Manager for changing remembered volumes and restore behavior independently for every pair.
- Keeps a local, deduplicated history of the latest 100 connections, including the connected and restored volumes.
- Temporarily pauses restoration for 15 minutes, one hour, or until manually resumed without allowing reconnect noise to overwrite memory.
- Offers optional failure-only or all-result restore notifications.
- Supports icon-only, icon-and-percentage, compact text, and full device-name menu-bar styles.
- Includes manual restore, save, automatic-restore, and launch-at-login controls.

## Install a release

Download `AirPods-Volume-v2.0.0-arm64.zip` from the repository's Releases page, unzip it, and move **AirPods Volume** to `/Applications`.

How to run:
Since this is not a notarized application, you must grant it permission to run. You can do so as follows:
- Try opening the app once and dismiss the warning.
- Open System Settings.
- Select Privacy & Security.
- Scroll down to the Security section.
- Find the message saying AirpodVolumeMacApp was blocked.
- Click Open Anyway.
- Authenticate with Touch ID or your Mac password.
- Click Open in the final confirmation.

Alternatively, you can clone the source code and build it yourself as follows:

## Build from source

Requirements:

- macOS 13 or newer
- Apple Silicon or Intel Mac
- Swift command-line tools

Run:

```sh
bash scripts/build-app.sh
```

The build script runs the controller tests, creates a release build for the current Mac architecture, packages it, and applies an ad-hoc signature. The result is:

```text
dist/AirpodVolumeMacApp.app
```

Open it with:

```sh
open dist/AirpodVolumeMacApp.app
```

To select a build architecture explicitly, set `AIRPODS_VOLUME_ARCH` to `arm64` or `x86_64`.

## Use

1. Connect the AirPods and select them as the current sound output.
2. Set the desired level with macOS controls or the app's menu slider.
3. Leave the menu-bar app running. On the next connection it restores and verifies that level.

Menu actions:

- **Restore Remembered Volume** retries the restore sequence immediately.
- **Save Current Volume** makes the current system value the remembered value.
- **Pause Restores** pauses for 15 minutes, one hour, or until resumed. Manual restore and save remain available.
- **Restore Automatically** enables or disables restoration globally.
- **Manage AirPods…** opens the Device Manager, connection history, and preferences. Opening the app again also opens this window.
- **Launch at Login** registers the app with macOS. A mixed checkmark means approval is still needed under System Settings > General > Login Items.

Moving the app's own slider or choosing **Save Current Volume** cancels any older reconnect attempt, so an intentional change cannot be overwritten by a delayed restore.

## Device Manager

The Device Manager has three tabs:

- **Devices** lists every remembered AirPods UID. Each device has its own remembered-volume slider, automatic-restore switch, connection details, and forget action. Editing an offline device changes only its saved value; editing the connected device applies the new value immediately.
- **History** shows which AirPods connected, the volume observed at connection, the verified restored volume, and whether restoration succeeded, failed, was paused, or was disabled. History can be cleared without forgetting devices.
- **Settings** controls global restoration, temporary pause, menu-bar appearance, and restore notifications.

All device records and the latest 100 history entries stay in `UserDefaults`. Existing remembered values from version 0.2 migrate when each device is next seen.

## Run tests

```sh
bash scripts/run-tests.sh
```

The test runner has no third-party dependencies and works with the standalone Apple Command Line Tools installation. Its 12 scenarios cover restore retries and verification, reconnect-noise suppression, intentional cancellation, temporary pause/resume, multiple unique devices, connection history and deduplication, preference persistence, reused CoreAudio device IDs, exact-value persistence, and renamed-device detection.

## Troubleshooting

- If the volume still changes after the menu reports a successful restore, choose **Restore Remembered Volume**. The final menu status will say whether the value was verified or did not stick.
- If a renamed AirPods device is not detected, verify that CoreAudio reports its manufacturer as Apple. A name or model identifier containing `AirPods` is always accepted.
- If launch at login shows a mixed checkmark, approve **AirPods Volume** in System Settings > General > Login Items.
- Only AirPods and Apple-manufactured Bluetooth audio devices are modified. Speakers and unrelated Bluetooth products are ignored.

## How it works

The app listens to CoreAudio's default-output-device property. When a supported Bluetooth output becomes active, it looks up the remembered scalar volume by the device's persistent UID. Restore passes run after 0.75, 2.25, and 5 seconds, followed by a final read-back verification. Volume notifications during that short window update the display but do not replace memory; later user changes are saved after a small debounce.

Both automatic and manual restore sequences are cancelled immediately when the active output changes, the app stops, or the user deliberately sets or saves a new volume.
