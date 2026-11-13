# Contributing to Tonalo

Thanks for helping out! This repo is public and the apps are released to real users, so a few simple rules keep `main` safe.

## Workflow

1. Work on your own branch (for example `milo`), never directly on `main`.
2. Commit small and often, in English, with a short imperative message ("Add queue screen").
3. When something works, open a **pull request** into `main`. Describe what you changed and how you tested it.
4. The maintainer reviews and merges. `main` is protected: direct pushes and force-pushes are blocked.
5. Releases, version bumps, tags and store uploads are done by the maintainer only. Do not create tags (`v*`), releases or edit `.github/workflows/`.

Keep your branch up to date with `git fetch origin && git merge origin/main`.

## Where things live

| Folder | What |
|---|---|
| `tv/` | LG webOS app (plain HTML, CSS, JavaScript) |
| `desktop/` | Electron app for Mac and Windows (shares code with `tv/`) |
| `ios/` | iPhone, Watch and CarPlay (Swift, SwiftUI) |
| `site/` | Website, deployed separately |
| `android/` | Android app (new) |
| `linux/` | Linux build (new) |

Your main folders are `android/`, `linux/` and `ios/`. For `tv/`, `desktop/` and `site/`, ask first: several apps share those files. Changes to `ios/` are welcome and reviewed like everything else.

The Android app talks to the same servers as the other apps (Navidrome/Subsonic, optionally Audiobookshelf). The Subsonic API behaviour is easiest to read in `tv/app/js/api.js` and `ios/Tonalo/`.

## Working on the iPhone app (`ios/`)

- Needs a Mac with Xcode. Build with the simulator, and say in the pull request what you tested and on which device or simulator.
- Xcode writes `DEVELOPMENT_TEAM` into `ios/Tonalo.xcodeproj/project.pbxproj` when signing. Reset that line before every commit (`git checkout -p` or edit it out). The team ID belongs only in `ios/Local.xcconfig`, which is ignored.
- Do not bump the build number or version, and do not archive or upload to App Store Connect. The maintainer does that.
- New texts go into `Localizable.xcstrings` with a German translation straight away (also Watch, Controls, App Shortcuts). Keep Xcode's file format: edit it in Xcode, do not rewrite it with a JSON library.
- Debug launch arguments like `-demoAccount` are listed in `AppModel.swift` and `TonaloApp.swift`.
- Server requests use `ServerSession`, never `URLSession.shared`. Credentials only in the Keychain.

## Privacy: this repo is public

Never commit:

- passwords, API keys, tokens, signing keys, keystores (`*.jks`, `*.keystore`), `google-services.json`, `local.properties`
- real server addresses, private domains, private IP addresses, real email addresses
- real names or device names, also not in screenshots or test data
- personal data of any kind

Use the mock server for testing: `node tv/tools/mock_server.js 4599` serves a fake Subsonic library without real data.

Commit with a GitHub noreply address (GitHub → Settings → Emails → "Keep my email addresses private"), so your real address does not end up in history.

## Security rules for code

- Credentials only in the platform's secure storage (Android Keystore), never in plain preferences or logs.
- Send credentials only over https, or over http inside the home network. Never forward them on a redirect to another host.
- No third-party servers, analytics or tracking SDKs. The app talks only to the user's own server.
- Show server data as plain text only.
- If `PRIVACY.md` or the Security section in the README no longer match what the app does, update them in the same pull request.

## Texts

- Code, comments and commit messages in English.
- User-visible texts in English and German (Android: `values/strings.xml` and `values-de/strings.xml`).
- No emojis in published texts. The shared-listening feature is called "Jukebox".
