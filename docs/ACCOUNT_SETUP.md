# Graphical account setup and persistent Dock attention

## Source-based design

The original Rclone Browser calls `qApp->alert(this)` when a transfer finishes. Qt's Cocoa platform calls `requestUserAttention:NSCriticalRequest` and cancels the stored request when alert state is cleared. Next uses the corresponding AppKit critical request, not an animation timer or repeated foreground activation. The main window must actually be presented before acknowledgment; menu-only activation keeps an unacknowledged result pending. Native tests cover the policy and execute the AppKit API. They do not assert visual Dock pixel motion on a user's desktop.

References:
- https://github.com/kapitainsky/RcloneBrowser/blob/45bf7411839b0919c488a3e3a0a5272b50c9fc7b/src/main_window.cpp
- https://github.com/qt/qtbase/blob/712c397090f36f8114b14eba24f1768301851c06/src/plugins/platforms/cocoa/qcocoawindow.mm
- https://developer.apple.com/documentation/appkit/nsapplication/requestuserattentiontype/criticalrequest

## Configuration protocol

Next owns its account dialog rather than embedding rclone's separate web GUI. The installed engine supplies providers through `rc --loopback config/providers`, its selected config path through `config/paths`, and account names/types through `listremotes --json`. Loopback dispatch here means invoking an RC method inside that process; no RC HTTP server is exposed.

`config create NAME TYPE --non-interactive --all` and `config update NAME --non-interactive --all --continue` return State/Option/Error JSON. State remains opaque in the native controller. Name, Help, Type, Required, Default, Exclusive, Examples and password metadata determine the form. Unknown additive fields are ignored; an unrecognized required response shape fails closed and offers terminal config. Before setup, command help is checked for the required flags.

Answers and continuation state use private child environment variables `RCLONE_RESULT` and `RCLONE_STATE`, not command-line arguments. `RCLONE_JSON` is intentionally not used: real rclone 1.75.2 registers another `--json` boolean flag that conflicts with that global environment variable. Ordinary output is bounded; stderr is drained without persistent logs. Only a validated local `/auth` URL is retained for the explicit reopen-browser control. Browser login itself is still managed by rclone.

References:
- https://rclone.org/commands/rclone_config_create/
- https://rclone.org/commands/rclone_config_update/
- https://rclone.org/rc/#config-providers
- https://rclone.org/drive/#making-your-own-client-id

## Commit and cancellation

A native maintenance lease prevents starting this setup while transfers, updates or conflicting tools are active. It stays held across browser authorization and all questions. Existing configuration is copied to an exclusive sibling `.rbn-account-UUID.conf` file. This preserves config-directory expansion semantics and permits same-filesystem atomic replacement. POSIX files are created mode 0600; Windows uses the existing native file helper and inherited ACLs. Existing encrypted config bytes remain encrypted, and the in-memory unlock password is supplied to the child through the existing process context.

Save requires a finished wizard, rereads the original and rejects replacement if its bytes changed since setup began, then uses the platform's atomic file replacement. This optimistic check prevents detected lost updates; it is not a distributed lock against arbitrary external writers. Normal cancellation terminates the child, waits for exit and removes its temporary file. A forced OS crash may leave a private sibling staging file; it is not treated as a saved account. No cloud credentials or personal configurations belong in test fixtures, source control, logs or handoff archives.

Only account names/types enter the account list. Stored secrets remain native; the GUI sees a blank password input and a keep-existing-value choice. New accounts require unique names. Removing an account requires confirmation and changes only the config entry.

## Verification

- `Tests/AccountSetupTests.swift`: installed rclone JSON questions, staged create/edit/delete, required/stale answers, external edits, duplicate names, Google/Microsoft pre-login flow, masking and callback URL validation.
- `Scripts/test-accounts.py`: the real compatibility helper, its maintenance gate and save/cancel lifecycle, run with disposable config files.
- `WebSource/tests/accounts.spec.ts`: GUI/terminal separation, explicit Save, cancellation, future fields, password defaults, required Google client ID, three languages and six themes.
- `Tests/MacCompletionTests.swift`: persistent request lifecycle, background/hidden windows, acknowledgment, deduplication, disabled setting, excluded states and AppKit invocation.

Provider tests reach Google's credential requirement and Microsoft's browser prompt without real cloud credentials. They do not claim successful sign-in to a real Google or Microsoft account. Future providers may introduce new field kinds or flows requiring support; terminal config remains available.
