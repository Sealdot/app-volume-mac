# Release security

## Current security posture

- No network client, microphone access, audio capture, virtual driver, administrator helper,
  updater, analytics SDK, or third-party runtime is included.
- Settings and the bounded event history remain local to the current macOS user.
- The app uses the default Core Audio output device and reads foreground App metadata only.
- No Hardened Runtime exceptions or resource-access entitlements are required.

`./scripts/build-app.sh` produces a Hardened Runtime build. Without
`VOLUME_GUARD_CODESIGN_IDENTITY`, it uses an ad hoc signature intended only for local development.
An ad hoc-signed bundle must not be presented as a trusted public binary.

## Developer ID release checklist

1. Use a clean, reviewed commit and run all checks:

   ```bash
   ./scripts/run-checks.sh
   ./scripts/build-app.sh
   ./scripts/ui-smoke-test.sh
   ./scripts/integration-volume-test.sh
   ./scripts/check-performance.sh
   ./scripts/security-check.sh
   ```

2. Build with a `Developer ID Application` identity. The identity name is not a secret:

   ```bash
   VOLUME_GUARD_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
     ./scripts/build-app.sh
   ```

3. Confirm Hardened Runtime, the certificate chain, and the secure timestamp:

   ```bash
   codesign --verify --deep --strict --verbose=2 dist/VolumeGuard.app
   codesign -d --verbose=4 dist/VolumeGuard.app
   ```

4. Archive and submit with a Keychain profile created by `notarytool store-credentials`:

   ```bash
   ditto -c -k --keepParent dist/VolumeGuard.app dist/VolumeGuard.zip
   xcrun notarytool submit dist/VolumeGuard.zip --keychain-profile VolumeGuardNotary --wait
   xcrun stapler staple dist/VolumeGuard.app
   xcrun stapler validate dist/VolumeGuard.app
   spctl --assess --type execute --verbose=4 dist/VolumeGuard.app
   ```

5. Publish a SHA-256 checksum with every binary release:

   ```bash
   shasum -a 256 dist/VolumeGuard.zip
   ```

Never commit Apple credentials, exported signing keys, notary passwords, Keychain files, or
provisioning secrets. GitHub release automation should use repository environments and the
minimum required permissions.

## Known boundaries

- The current local build is arm64-only.
- App Sandbox is not enabled because this build manages a user LaunchAgent directly. The process
  still runs without administrator privileges and requests no microphone or audio-capture access.
- Device hardware volume, external amplifiers, non-default output paths, and unsupported Core Audio
  devices remain outside the app's control.
