# Account configuration architecture (0.9.3)

`AccountSetup.tsx` presents quick and detailed forms. `Sources/Core/AccountConfiguration.swift` owns a staged native session, while `AccountSetupPolicy.swift` supplies reviewed defaults for common browser sign-in. macOS and the Tauri compatibility host share this core and renderer.

## Interaction model

Quick setup is the default. Name and service are on one page; Google Drive, OneDrive and Dropbox are ordered first. Browser-login services have an optional, collapsed pair of custom client credentials. The primary action explicitly means sign in **and add the account**, and requests `autoSave: true`. A successful session commits through the same atomic-save implementation as explicit Save. Detailed setup and editing retain explicit Save. Server services show their necessary address and authentication fields.

Detailed setup is also a form. It uses sanitized `config providers` options, groups ordinary and advanced fields, and displays provider-specific options when applicable. Familiar fields and Drive scopes have localized labels; original field names and documentation are available in a disclosure. Unknown runtime questions are a recovery path for new information, not the normal sequence for browser login.

`info.requiresUnlock` is true only when the selected file has rclone's encryption header and the selected engine cannot read its remotes. An already-unlocked encrypted file does not show a password prompt. Configuration-file controls are secondary to creating an account.

## Native protocol and policy

The engine provides `config providers`, `config create/update --all --non-interactive` and `config update --continue`. `State`, `Option`, `Error` and empty terminal `State` are rclone's documented application protocol. State strings remain opaque; no provider numbers, terminal-menu positions or encoded state internals are used.

The start request supplies `setup: quick|detailed`, a dictionary of `fields`, `useSharedClient`, and `autoSave`. Field names must be present in this provider's configurator schema. The native worker applies form fields to corresponding rclone questions and retains current native defaults for omitted fields. It enables the advanced round when submitted fields need it. If a submitted field never applies, completion stops instead of claiming that field saved. Legacy clients that omit setup and fields retain the explicit-question protocol.

The quick OAuth profiles are bounded:

- Drive chooses its advertised normal read/write scope, browser authorization, personal Drive by default, and the built-in client only when the form selected it. It does not accept the upstream shared-client question's false default and accidentally route a blank form to mandatory custom credentials.
- OneDrive chooses its advertised ordinary OneDrive connection. A single returned drive can be selected automatically; multiple choices require the user's decision. Detailed setup can expose other connection choices.
- Dropbox uses the built-in browser flow and current provider defaults.

Values still go through rclone validation. Missing required values, unsupported choices, validation errors, unknown dynamic questions and repeated state/answer pairs return control to the UI. An overall automatic-step bound prevents unbounded loops. Error recovery preserves a route back to the form and waits for cancellation cleanup before starting a replacement session.

`RCLONE_STATE` and `RCLONE_RESULT` carry continuation data in the child environment, never argv. RC `config/paths` uses `rc --loopback`, which runs in-process without an RC HTTP listener. A long-running control server is not needed.

## Transaction boundary

Information discovery reserves an engine operation. A staged session acquires the existing maintenance gate only after active transfers and captures finish. Setup cannot overlap app-managed engine replacement or connection-path changes. Native hosts also reject starting it during terminal setup or active mounts/streams.

A private, exclusively created staging config is placed beside the original so relative credential-file paths keep their meaning. Original contents stay in memory as the conflict baseline. Continuation and optional read-only connection testing operate on the staged config. Both automatic add and explicit Save compare original bytes, flush a private temporary file and atomically replace the target. An external edit rejects save. This detects normal external edits but is not an operating-system-wide lock against another process writing at precisely the same instant.

Cancel and normal shutdown terminate the owned rclone child, remove the staged config and its `.old` companion, clear transient private values and release the gate once. An OS crash or forced kill can leave an owner-private `.rbn-account-*.conf` beside the original; do not collect such files in diagnostics or source handoffs. Cancelling discards local configuration; a service can retain an OAuth grant that it already issued.

## Credentials and browser login

Existing sensitive defaults stay in the native session. The renderer receives an empty default and `HasSavedValue` when an explicit question needs it. New secrets remain transient UI/native state and child environment or stdin; they are not appended to argv, app logs or diagnostics. Provider-schema secret defaults are stripped from discovery responses.

rclone's `--all` continuation does **not** automatically obscure an `IsPassword` answer. Newly entered passwords therefore go through the selected engine's `rclone obscure -` over stdin before continuation receives them. Existing encoded defaults are preserved verbatim, avoiding double encoding. Sensitive OAuth client secrets without `IsPassword` are not transformed. Obscuring is rclone's reversible representation, not encryption; encrypted configurations retain rclone's own file-encryption behavior.

Browser authorization remains rclone's responsibility. For form-driven sessions, automatic browser launch inside the child is disabled; the UI requests one native open when the child advertises its current loopback `/auth` URL with a state parameter. A manual reopen action remains available. The renderer never supplies an arbitrary URL to that opener. Diagnostic URL extraction serves only to open the active authorization page, not to interpret configuration state.

The snapshot records `authorizationStarted`. After browser authorization, each native host shows its window once when the session completes, needs an additional choice such as a OneDrive drive selection, or reports an error. Subsequent polls do not repeatedly activate it. Local setup without browser authorization and cancelled sessions do not trigger this behavior.

The current rclone includes its shared Drive client while announcing retirement during 2026. This application can initiate that flow but cannot guarantee Google's continued acceptance. A rejected built-in login can be retried with custom Client ID and Secret entered together. No shared identifier owned by this project is fabricated or substituted.

## Upstream GUI research

The current official `rclone gui` uses `rclone/rclone-web`; the older `rclone-webui-react` repository is archived. Current `RemotesNew.tsx` combines name, backend and ordinary fields on one page, folds advanced fields, and submits a parameter object to `config/create`. This project adopts that form structure while keeping staged native configuration, explicit completion detection and bounded recovery. It does not embed a second GUI or infer success merely from a nonempty config file.

Reviewed sources are pinned to rclone v1.75.2 and rclone-web commit `f31d8068bb16a02282e070ed30077c6cadd13394`:

- https://rclone.org/gui/
- https://github.com/rclone/rclone-web/blob/f31d8068bb16a02282e070ed30077c6cadd13394/src/pages/RemotesNew.tsx
- https://rclone.org/commands/rclone_config_create/
- https://rclone.org/commands/rclone_config_providers/
- https://rclone.org/commands/rclone_obscure/
- https://rclone.org/rc/#config-paths-read-the-config-paths
- https://rclone.org/drive/#making-your-own-client-id
- https://rclone.org/onedrive/
- https://github.com/rclone/rclone/blob/v1.75.2/backend/drive/drive.go
- https://github.com/rclone/rclone/blob/v1.75.2/backend/onedrive/onedrive.go
- https://github.com/rclone/rclone/blob/v1.75.2/fs/config/ui.go

## Reproduce and limits

Run `Tests/AccountsTests.swift` with the pinned rclone in an isolated native build. `WebSource/tests/accounts.spec.ts` checks form submissions, browser waiting, retries, cancellation, explicit save, generic recovery, translations and layout against a synthetic native bridge. Full cloud login requires the account owner's interactive consent; neither synthetic UI fixtures nor the real local OAuth listener establish that a cloud provider has accepted a particular real account.

The 0.9.2 Dock attention implementation is retained. It uses AppKit `.criticalRequest`, shares outstanding attention across jobs and cancels on activation, disable or termination. This is application-focus behavior, not pixel-by-pixel window-occlusion detection; OAuth's one-time return to the app is a separate action.
