# Account configuration architecture (0.9.2)

The native core in `Sources/Core/AccountConfiguration.swift` owns one staged account session. `AccountSetup.tsx` presents the questionnaire; macOS and Tauri use the same API.

## Why this interface

Use `config providers`, `config create/update --all --non-interactive`, then `config update --continue`. `State`, `Option`, `Error` and an empty terminal `State` are rclone's documented application protocol. `RCLONE_STATE` and `RCLONE_RESULT` supply the two flags through the child environment, not command-line arguments. The selected rclone supplies each next question, including provider-specific OAuth choices; neither backend numbers nor terminal prompts are parsed.

`DefaultStr` is used when available, preserving rclone's canonical formatting for booleans, durations, sizes and list-valued options. Unknown fields use a generic input and remain validated by rclone. Unsupported JSON or missing protocol capability fails without applying the staged changes; `config` remains available. This does not promise compatibility with arbitrary future protocol changes.

The RC `config/paths` endpoint is invoked with `rc --loopback`, which runs in-process without an RC HTTP listener. We do not embed rclone's separate Web GUI, host an unauthenticated control server, or parse its terminal menus.

## Transaction boundary

Information discovery reserves an engine operation. A staged session acquires the existing maintenance gate only after active transfers and captures have finished. Setup cannot overlap app-managed engine replacement or connection-path changes. Native hosts also reject starting it during terminal setup or active mounts/streams.

A private, exclusively created staging config is placed beside the original so relative credential-file paths keep their meaning. Original contents are kept in memory as the conflict baseline. JSON continuation and optional read-only connection testing operate only on that staged config. Save checks the original bytes, flushes a private temporary file and atomically replaces the target; an external edit rejects save. This detects normal external edits but is not an operating-system-wide lock against another process writing at precisely the same instant.

Cancel and normal shutdown terminate the owned rclone child, remove the staged config and its `.old` companion, and release the gate once. An OS crash or forced kill can leave an owner-private `.rbn-account-*.conf` beside the original; do not collect such files in diagnostics or source handoffs. A service may retain an OAuth grant after cancelling locally; cancelling discards local configuration, not remote account authorization.

## Credentials and browser login

Existing sensitive defaults stay in the native session. The renderer receives an empty default plus `HasSavedValue`, and returns a keep/default flag. New secrets are only transient UI/native state and child environment; they are never appended to argv, app logs or diagnostics. rclone retains its normal obscuring/encrypted-config behavior. No credentials or signed login URLs are included in public tests.

Browser login is handled by rclone. The host may reopen only the current child-provided loopback `/auth` URL with a state parameter, not an arbitrary URL supplied by the renderer. That URL is parsed from rclone's diagnostic URL output solely as a convenience for reopening an already-running browser flow, not for configuration state or question interpretation. If a future rclone changes this diagnostic line, its own automatic browser launch still applies and terminal setup remains available.

## Reproduce

Run `Tests/AccountsTests.swift` with the pinned rclone in an isolated native build. It covers staging, cancellation, conflicts, secret retention, account removal, Unicode names and real Google/OneDrive pre-authentication questions. `WebSource/tests/accounts.spec.ts` checks the UI protocol, cancellation, confirmation, generic questions and layout. Full cloud login requires the account owner's interactive consent and is not represented by these fixtures.

## Sources

- https://rclone.org/commands/rclone_config_create/
- https://rclone.org/commands/rclone_config_providers/
- https://rclone.org/rc/#config-paths-read-the-config-paths
- https://rclone.org/drive/#making-your-own-client-id
- https://rclone.org/onedrive/
- https://github.com/rclone/rclone/blob/v1.75.2/fs/config/flags/flags.go
- https://github.com/kapitainsky/RcloneBrowser/blob/45bf7411839b0919c488a3e3a0a5272b50c9fc7b/src/main_window.cpp
- https://doc.qt.io/qt-6.8/qapplication.html#alert
- https://developer.apple.com/documentation/appkit/nsapplication/requestuserattentiontype/criticalrequest

The original application calls `qApp->alert(this)` on completion: Qt's default zero duration persists until activation. 0.9.1 used `.informationalRequest`; 0.9.2 uses `.criticalRequest`, has no expiry timer, shares outstanding attention across jobs, and cancels it on activation, settings disable, or termination. This is application-focus behavior, not pixel-by-pixel window-occlusion detection.
