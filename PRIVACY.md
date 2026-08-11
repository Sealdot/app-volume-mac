# Privacy

VolumeGuard is designed to work entirely on the Mac where it is installed.

## Data accessed

- the default audio output device name, software volume scalar, mute state, and whether the
  device exposes writable system volume controls;
- the current foreground application's display name and bundle identifier, for optional App rules;
- basic metadata from an `.app` explicitly selected in the macOS file picker.

VolumeGuard does not open an audio stream, read audio content, access the microphone, install a
virtual audio device, or send analytics, crash reports, settings, or usage data over the network.

## Data stored locally

- protection settings and App rules;
- up to 20 recent protection events containing time, application name, output device name, and
  the before/after volume percentages;
- an optional user-owned LaunchAgent plist when “登录时启动” is enabled.

Settings and events use the app's local `UserDefaults` domain. Protection notifications can include
an application name and volume percentages, and macOS may show them on the lock screen according
to the user's notification settings.

## Removing local data

Disable “登录时启动”, quit VolumeGuard, delete the app, and run:

```bash
defaults delete com.volumeguard.app
```

If the login item was not disabled first, also remove
`~/Library/LaunchAgents/com.volumeguard.app.plist`.
