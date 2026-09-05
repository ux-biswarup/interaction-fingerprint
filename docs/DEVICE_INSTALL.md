# Installing on a physical iPhone

ARKit face tracking does not run in the Simulator. Every recording session needs the app
installed on a Face ID iPhone. This page is the repeatable procedure.

## One-time setup

### 1. Sign in to Xcode

Xcode → Settings → Accounts → add or re-select your Apple ID. A free Apple ID works; it
appears as a "Personal Team".

The login expires periodically. When it does, device builds fail with:

```text
Unable to log in with account '<your-apple-id>'. The login details were rejected.
No profiles for 'com.biswarupmondal.InteractionFingerprint' were found.
```

The fix is always the same: re-enter your password in Xcode → Settings → Accounts.
There is no command-line workaround for a free account, because App Store Connect API keys
require a paid membership.

### 2. Set your team

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Put your 10-character team ID in `DEVELOPMENT_TEAM`. Find it in Xcode → Settings → Accounts,
or run:

```bash
defaults read com.apple.dt.Xcode IDEProvisioningTeams
```

`Config/Local.xcconfig` is git-ignored, so your personal team ID never enters the public repo.
If the bundle identifier is already taken by another Apple account, override
`PRODUCT_BUNDLE_IDENTIFIER` in the same file.

### 3. Prepare the phone

- Connect by USB and tap **Trust This Computer**.
- Settings → Privacy & Security → **Developer Mode** → on, then restart the phone.
- Keep the phone unlocked during install.

Verify the phone is visible:

```bash
xcrun devicectl list devices
```

## Build, install, and launch

```bash
xcodebuild -workspace InteractionFingerprint.xcworkspace \
  -scheme InteractionFingerprint \
  -destination 'id=<DEVICE-UDID>' \
  -allowProvisioningUpdates \
  build
```

`-allowProvisioningUpdates` lets Xcode create the signing certificate and provisioning profile
on first use. Take the UDID from `xcrun devicectl list devices`.

With XcodeBuildMCP the device workflow is enabled in `.xcodebuildmcp/config.yaml`, so an agent
or the CLI can do the whole thing in one step:

```bash
xcodebuildmcp device build-and-run --device-id <DEVICE-UDID>
```

## First launch on the phone

1. Tapping the icon shows "Untrusted Developer" the first time. Go to
   Settings → General → VPN & Device Management, select your Apple ID, and tap **Trust**.
2. The app asks for camera access. Grant it. The prompt text is set by
   `INFOPLIST_KEY_NSCameraUsageDescription` in `Config/Shared.xcconfig`.
3. The home screen should report that face tracking is supported. If it says unavailable, the
   device lacks Face ID or the build landed on the wrong destination.

## Free personal team limits

| Limit | Value |
| --- | --- |
| App validity before it must be rebuilt | 7 days |
| New App IDs per rolling 7 days | 10 |

A paid Apple Developer Program membership removes the 7-day expiry. For a research study that
runs longer than a week, either rebuild before each session or use a paid account.

## Troubleshooting

- **"invalid code signature, inadequate entitlements or its profile has not been explicitly
  trusted by the user"** when launching from the command line: the app installed fine, but the
  developer certificate is not trusted yet on the phone. Do the Trust step above. This is
  required once per certificate, not once per build.
- **"The login details were rejected"**: re-sign in, see step 1 above.
- **"No profiles were found"**: almost always the same login problem, not a project problem.
- **Device shows `unavailable`**: unlock the phone, re-plug the cable, re-trust the computer.
- **App installs but quits immediately**: the 7-day profile expired. Rebuild.
- **Compilation is fine but signing fails**: verify with an unsigned device build, which proves
  the code is not at fault:

  ```bash
  xcodebuild -workspace InteractionFingerprint.xcworkspace -scheme InteractionFingerprint \
    -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
  ```
