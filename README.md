# AirPods Volume Memory

A tiny native macOS menu-bar app for Apple Silicon Macs to fix the annoying bug where each time you connect your airpods, the volume resets to 50%. It watches the current output audio device, remembers the volume you set for AirPods, and restores that volume the next time those AirPods become the active output device.

## How It Works

macOS exposes audio devices through CoreAudio. This app listens for two things:

1. The default output device changes.
2. The active AirPods output volume changes.

When the default output device name contains `AirPods`, the app saves that device's volume under its CoreAudio device UID. On a later reconnect, it waits briefly for the Bluetooth device to finish becoming available and then restores the saved volume.

The saved value is stored locally in `UserDefaults`. Nothing leaves your Mac, this is a fully offline app.

## How to Download And Install
Download the file ```AirpodVolumeMacApp.app.zip``` from the Releases section to get the latest version of the compiled app. Unzip and open the ```AirpodVolumeMacApp.app``` to run, and follow the instructions in the "To Set Start At Login" section below to allow the app to open automatically on boot. Alternatively, if you want to build the compiled binary for the app yourself, follow the instructions below:

## Requirements To Build 

- Apple Silicon Mac.
- macOS 13+.
- Swift command-line tools.

## To Build The App

From this folder, run:

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
```

The app bundle is created at:

```text
dist/AirpodVolumeMacApp.app
```

## To Run

Start the app with:

```sh
open dist/AirpodVolumeMacApp.app
```

You should see `AirPods Vol` in the macOS menu bar. There is no Dock icon because this is a background menu-bar utility.

## Usage

1. Connect your AirPods to the Mac.
2. Make sure they are the selected output device.
3. Set the AirPods volume to the level you want remembered, either with macOS controls or with the slider in the app's menu-bar menu.
4. Leave the app running.
5. Disconnect and reconnect the AirPods.

When the AirPods reconnect as the active output, the menu-bar title should update and the app should restore the remembered volume.

The slider is enabled only when AirPods are the current output device. Moving it sets the AirPods volume immediately and saves that value for the next reconnect. You can also choose `Save Current Volume Now` if you want to force-save the current AirPods volume.

## To Set Start At Login

After building, you can have macOS launch it automatically:

1. Open System Settings.
2. Go to General > Login Items.
3. Press `+`.
4. Select `dist/AirpodVolumeMacApp.app`.

If you prefer, move `dist/AirpodVolumeMacApp.app` to `/Applications` first and add that copy as the login item.

## Things To Note

- The app only touches output devices whose name contains `AirPods`.
- If you renamed your AirPods to a name without `AirPods`, rename them back or adjust `AudioDevice.isAirPods` in `Sources/AirpodVolumeMacApp/AudioDevice.swift`.
- Some devices expose a single master volume, while others expose left and right channels. The app supports both.

