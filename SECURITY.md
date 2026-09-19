# Security Policy

Snappy is maintained by a single developer. While I take security seriously, I appreciate your patience and responsible disclosure to help protect Snappy users.

## Supported Versions

Security fixes are applied only to the latest stable release.

| Version | Supported |
| ------- | --------- |
| Latest  | ✅ Yes    |
| All Past| ❌ No     |

## Scope and Privileges

Snappy requires **macOS Accessibility Permissions** (`AXUIElement`) to manage windows. 

* **Local Only:** Snappy runs entirely locally. It never collects, logs, or transmits window layouts, keystrokes, or personal data.
* **Network Access:** Exactly one connection, to `getsnappy.fyi`, made by the Sparkle updater to fetch the appcast and download a new version. No analytics, no crash reporting, no remote configuration. The bundled `InternetAccessPolicy.plist` declares it, so tools like Little Snitch can confirm the scope independently.
* **Update Integrity:** Every update is signed with an EdDSA key whose public half ships inside the app, and Sparkle refuses anything that fails verification. Builds are also Developer ID signed and notarized.

## Reporting a Vulnerability

**Please do not open a public GitHub issue or discussion for security bugs.**

If you find a vulnerability, please report it privately:

* **Email:** help@getsnappy.fyi

### Please Include:
1. A brief description of the issue and potential impact.
2. Step-by-step instructions (or a proof-of-concept script) to reproduce it.
3. Your version of Snappy and macOS.

I will review your report and respond within 48 hours to coordinate a patch and public disclosure.

