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
- Includes manual restore, save, forget, automatic-restore, and launch-at-login controls.

## Install a release

Download `AirpodVolumeMacApp.app.zip` from the repository's Releases page, unzip it, and move **AirPods Volume** to `/Applications`.

The first time you open an independently distributed build, macOS may ask you to confirm that you trust it. Once the app is running, use **Launch at Login** in its menu if you want it to start automatically.

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
- **Forget Remembered Volume** removes the saved value for the active AirPods.
- **Restore Automatically** pauses or resumes reconnect restoration without quitting the app.
- **Launch at Login** registers the app with macOS. A mixed checkmark means approval is still needed under System Settings > General > Login Items.

Moving the app's own slider or choosing **Save Current Volume** cancels any older reconnect attempt, so an intentional change cannot be overwritten by a delayed restore.

## Run tests

```sh
bash scripts/run-tests.sh
```

The test runner has no third-party dependencies and works with the standalone Apple Command Line Tools installation. It covers restore retries and verification, reconnect-noise suppression, cancellation after intentional changes or device switches, reused CoreAudio device IDs, manual behavior while automatic restore is paused, exact-value persistence, and renamed-device detection.

## Troubleshooting

- If the volume still changes after the menu reports a successful restore, choose **Restore Remembered Volume**. The final menu status will say whether the value was verified or did not stick.
- If a renamed AirPods device is not detected, verify that CoreAudio reports its manufacturer as Apple. A name or model identifier containing `AirPods` is always accepted.
- If launch at login shows a mixed checkmark, approve **AirPods Volume** in System Settings > General > Login Items.
- Only AirPods and Apple-manufactured Bluetooth audio devices are modified. Speakers and unrelated Bluetooth products are ignored.

## How it works

The app listens to CoreAudio's default-output-device property. When a supported Bluetooth output becomes active, it looks up the remembered scalar volume by the device's persistent UID. Restore passes run after 0.75, 2.25, and 5 seconds, followed by a final read-back verification. Volume notifications during that short window update the display but do not replace memory; later user changes are saved after a small debounce.

Both automatic and manual restore sequences are cancelled immediately when the active output changes, the app stops, or the user deliberately sets or saves a new volume.
