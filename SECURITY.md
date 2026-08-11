# Security Policy

## Supported versions

| Version | Security updates |
|---|---|
| 0.4.x | Yes |
| 0.3.x and earlier | No |

Please reproduce an issue with the latest release or the default branch before reporting it.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use
[GitHub private vulnerability reporting](https://github.com/Sealdot/app-volume-mac/security/advisories/new)
so the report and any proof of concept remain private.

Please include:

- the affected version and macOS version;
- the output device type involved;
- clear reproduction steps and expected impact;
- logs or a minimal proof of concept with personal data removed.

The maintainers will acknowledge a complete report as soon as practical, validate the impact,
and coordinate a fix and disclosure. There is currently no paid bug bounty.

## Security boundaries

VolumeGuard reduces accidental high system volume. It is not a medical device or a security
boundary, and it cannot control a physical amplifier, hardware volume knob, unsupported output
device, or an application that bypasses the default macOS output path.

Reports about code execution, unsafe installation or update behavior, unauthorized data access,
permission escalation, signature or release integrity, and reliable protection bypasses are in
scope. General feature requests and device compatibility reports belong in regular GitHub issues.
