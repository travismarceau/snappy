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
* **No Network Access:** Snappy makes no network connections of any kind. It has no updater, no analytics, and no remote configuration. The bundled `InternetAccessPolicy.plist` declares this, so tools like Little Snitch can confirm it independently.

## Reporting a Vulnerability

**Please do not open a public GitHub issue or discussion for security bugs.**

If you find a vulnerability, please report it privately:

* **Email:** help@getsnappy.fyi

### Please Include:
1. A brief description of the issue and potential impact.
2. Step-by-step instructions (or a proof-of-concept script) to reproduce it.
3. Your version of Snappy and macOS.

I will review your report and respond within 48 hours to coordinate a patch and public disclosure.

