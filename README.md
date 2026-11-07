# Lidlight

**A small, open-source macOS utility for timed closed-lid keep-awake sessions.**

Choose a duration, authorize the session, and monitor it from a native window or the menu bar. Lidlight is independently implemented; it does not contain Amphetamine code and is not affiliated with Amphetamine or its developer. It is a focused alternative, not a complete replacement for Amphetamine's features.

## Features

- 15-, 30-, 60-, and 120-minute sessions.
- Native AppKit window and menu-bar controls.
- Visible countdown and explicit activation status.
- Separate privileged watchdog to restore normal sleep when the timer expires, you stop or quit, or the app stops responding.
- Stops at 20% battery when running on battery power.
- The app requests a stop on serious or critical macOS thermal pressure.
- No network access, analytics, third-party runtime, login item, permanent helper, or passwordless sudo rule.

## Requirements

- macOS 13 or later (deployment target; not a claim of testing every supported release).
- An administrator account to authorize power-setting changes.
- Xcode Command Line Tools to build from source (`xcode-select --install`).

Currently built and tested on one Apple Silicon Mac. Intel builds and other macOS versions are not independently validated.

## Build and install

```sh
git clone https://github.com/azoghby/lidlight.git
cd lidlight
./build.sh --install
open "$HOME/Applications/Lidlight.app"
```

Without `--install`, `./build.sh` creates `build/Lidlight.app`. The script compiles for the current Mac's architecture and applies an ad-hoc code signature. The app is not Apple-notarized or distributed through the App Store.

Quit an installed copy before rebuilding or installing over it.

## Use

1. Open Lidlight and choose a duration.
2. Approve the macOS administrator prompt.
3. Wait for **Closed-lid session active** before closing the lid.
4. Use **Stop and restore normal sleep** to end early. Closing the window leaves the menu-bar app running; use its Quit command to exit.

Keep the Mac ventilated. **Do not keep it running inside a closed bag.** Remote agents still require an internet connection, which may change or disappear while traveling.

Test a brief lid close/reopen on your own Mac before relying on this. Verifying the power setting is not proof that a particular workload continues with the lid closed.

## How it works

For the duration of a session, a short-lived administrator-authorized instance of the app changes the system-wide `pmset disablesleep` setting. It watches the main app's heartbeat, process, deadline, and battery level, then restores the setting. The main app also holds an idle-sleep assertion and observes thermal pressure.

Lidlight refuses to start if system sleep is already disabled by another utility. The watchdog rechecks the setting to handle resets after power-source changes. Avoid running competing closed-lid utilities simultaneously.

The privileged watchdog stores session status and a lock in `/var/run/io.github.azoghby.lidlight`. It is not installed as a launch daemon. Authentication is handled by macOS; Lidlight does not collect or store your administrator password.

## Limitations and recovery

- The setting is system-wide and can prevent manual sleep during a session.
- Watchdog checks and restoration take several seconds; emergency battery or thermal behavior is not guaranteed.
- A main-app crash is handled by the watchdog. Force-killing the privileged watchdog, an unexpected system failure, or a failure restoring the setting can require manual recovery.
- A forcibly terminated watchdog can leave a stale session lock. Do not delete an active session's lock; restarting the Mac clears this `/var/run` state.
- This is an early implementation, not an independently audited system utility.

If normal sleep has not returned, restore it in Terminal:

```sh
sudo pmset -a disablesleep 0
```

Then verify with:

```sh
pmset -g
```

`SleepDisabled` should be `0` or absent. Other utilities, including `caffeinate`, can still independently prevent idle sleep.

## Verification

```sh
./build.sh
./build/Lidlight.app/Contents/MacOS/Lidlight --self-test
codesign --verify --verbose ./build/Lidlight.app
```

The self-test covers shell quoting, a missing heartbeat, and read-only system-state inspection. It does not activate closed-lid mode or validate physical lid behavior.

The original implementation was manually verified to enable and restore `SleepDisabled` and render the controls. Additional hardware and failure-mode testing is welcome. After a rename or other change, repeat the privileged activation/restoration test before relying on it.

## Contributing

Issues and pull requests are welcome, especially for compatibility reports, recovery behavior, and safer power-management integration. Include your Mac model, macOS version, and whether the issue occurs on battery or external power. Do not post credentials or private logs.

## License

[MIT](LICENSE). Copyright 2026 Alex Zoghby.
