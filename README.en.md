# VolumeGuard (音量卫士)

[简体中文](README.md) · [English](README.en.md)

VolumeGuard is a lightweight, native macOS menu bar app that lowers unexpected high system volume when the foreground app or output device changes, while respecting later manual volume adjustments.

**Project status:** Open source under the MIT License. The app version in the current source tree is 0.5.0. The current build targets Apple Silicon Macs. The app interface is currently in Simplified Chinese; the project documentation is available in Chinese and English.

## Download and install

- [Download the v0.5.0 source ZIP](https://github.com/Sealdot/app-volume-mac/archive/refs/tags/v0.5.0.zip), or [download the latest source on the default branch](https://github.com/Sealdot/app-volume-mac/archive/refs/heads/codex/volume-guard-macos.zip).
- There is currently no signed and notarized installer. The source ZIP must be built on a Mac before you can run the app.
- The current build targets arm64, so it does not support Intel Macs.

With Apple Command Line Tools installed, run:

```bash
./scripts/run-checks.sh
./scripts/build-app.sh
open dist/VolumeGuard.app
```

To install the locally built app in `/Applications`, run `./scripts/install.sh`. A local development build is signed ad hoc; see the [release security checklist](docs/RELEASE_SECURITY.md) for requirements before distributing a binary.

## Features

- Default output-device protection level, initially 20%.
- Smart scene protection or a strict volume ceiling.
- Rules for the foreground app, individual output devices, and device types.
- Smart mode preserves volume changes made with the keyboard or Control Center until the next app, device, wake, or settings change.
- Optional mute, lower-volume, or no-action behavior when switching from headphones to another output.
- Checks on app launch, foreground-app change, output-device change, and wake from sleep.
- Temporary pause, launch at login, local settings, and a short local protection history.
- No audio recording, virtual audio driver, network access, analytics SDK, or third-party runtime dependency.

VolumeGuard only lowers system volume. It cannot control an external amplifier, a device without writable macOS volume, audio routed outside the default output path, or instantaneous loudness within the audio signal. See the [product specification](docs/PRODUCT_SPEC.md), [privacy notice](PRIVACY.md), and [security policy](SECURITY.md) for details.

## License

VolumeGuard is available under the [MIT License](LICENSE).
