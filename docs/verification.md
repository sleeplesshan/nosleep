# Verification and recovery

## Automated checks

Run `swift test` for strict state parsing, failed/contradictory readback, external changes, concurrent requests, original error preservation, and lid transition/cooldown behavior. These tests use fake power backends and never invoke pmset setters.

Run `bash scripts/build.sh` for an optimized app bundle and signature verification. `Sleeplesshan --diagnose` reads current power, lid, permission, and legacy-watcher information without mutation.

## Real-device acceptance

Record actual observations instead of treating a successful command exit as proof that a display turned off or a session locked.

- Change sleep prevention in the app; check `pmset -g` and the menu-bar indicator.
- Change the same setting from an external tool; check the visible app within one polling interval.
- Cancel an administrator dialog on a Mac that needs it; verify there is no false success or optimistic state.
- Close and reopen the window; confirm menu-bar operation continues.
- Quit and restart; confirm the global setting is unchanged.
- Test hardware brightness-zero with prevention ON and OFF; verify the measured brightness reaches zero and restores on input without display sleep. Verify an app-owned idle-display assertion exists only during the dimmed session.
- Test lock-and-display-off; wake and confirm actual authentication is required.
- Close/open the physical lid while prevention is ON and confirm work continues and the chosen display action occurs once. Test an external monitor separately.
- Verify login registration on the installed app and a real login session.
- Check both languages, dark appearance, keyboard traversal, and VoiceOver labels.

Hardware, authentication, and login-session checks cannot be inferred from unit tests. See the release's recorded results for checks actually completed.

## Migration and recovery

The optional import only recognizes the original `local.han.display-sleep-on-lid-close` watcher with its exact expected script configuration. New installs never need this import.

Migration requires a known lid state, Accessibility permission, and enabled login registration. The previous plist and script are backed up under `~/Library/Application Support/NoSleep/Backups/`. Sleeplesshan verifies the old launch service is absent before removing its original plist, and sets its own lid action to lock-and-display-off. Other power agents and idle-sleep settings remain unchanged.

To restore a backup:

1. Quit Sleeplesshan.
2. Run `bash scripts/restore-lid-watcher.sh '/path/to/the/backup-directory'`.
3. The old configuration must not already exist; the restore script refuses to overwrite it.
4. On reopening, Sleeplesshan detects the restored watcher and suspends its own automatic lid actions to avoid duplicates.

## Removing Sleeplesshan

Choose your desired sleep-prevention state first. Disable login launch, then quit the app and remove it. Quitting or deleting Sleeplesshan intentionally does not silently change the global sleep-prevention setting. You can independently restore normal permission for sleep using `sudo /usr/bin/pmset -a disablesleep 0`.

## Known limits

The lock action uses the standard Control–Command–Q shortcut through public CGEvent APIs. Sending a keyboard event has no lock-completion response; a remapped or intercepted shortcut may not lock. The app reports requests and requires a real authentication test before relying on this flow. Sleeplesshan does not change password policies or use private lock APIs.

Sleep prevention does not guarantee uninterrupted operation under battery depletion, thermal protection, or every hardware/OS configuration. New installs default to no automatic lid action. The app must remain running for lid automation.

Brightness uses guarded DisplayServices SPI on supported built-in panels. A recovery journal is saved before writes, and partial failure is rolled back. Recovery entries for temporarily disconnected displays must be retained. External displays have no gamma/overlay fallback.

## Recorded local results — 2026-10-25

- 32 automated tests passed (24 core, including 14 brightness-session cases, and 8 process-adapter tests). Release build and installed bundle signature verification passed.
- App-to-system changes and changes from the existing external control scripts synchronized with the app. Closing/reopening the window and quitting/relaunching preserved the global setting.
- Built-in brightness reached exactly 0 and returned to the saved value on pointer input in two measured runs. The user confirmed restoration without a password. No display-idle assertion remained afterward.
- The user confirmed a password was required when returning from the lock-and-display-off check. This verifies this Mac’s observed behavior, not all shortcut or password-policy configurations.
- The previous lid watcher was backed up and stopped; its launch service was absent after migration. The unrelated idle-sleep agent was preserved.
- English and Korean controls, bundled Paperlogy fonts, and dark appearance were inspected. Login registration was enabled in the installed app.
- Still pending physical acceptance: closing/reopening the lid while work runs, external-monitor behavior, a real logout/login cycle, full keyboard traversal and VoiceOver, and light appearance. These are not covered by the automated-test result.
