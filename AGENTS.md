# Tonalo: instructions for AI assistants (Claude Code and others)

Tonalo is a client for Navidrome/Subsonic servers and Audiobookshelf. The repo is **public**.
Contributor: Milo, building the Android app (`android/`) and maybe a Linux build (`linux/`).
The full rules are in `CONTRIBUTING.md`: read it first. Short version:

## Git
- Work only on branch `milo`. Update with `git fetch origin && git merge origin/main`.
- Never commit or push to `main` (protected). Finished work goes in a pull request `milo` -> `main`.
- No tags (`v*`), releases, version bumps, store uploads, or edits to `.github/workflows/`. Maintainer only.
- Commit small and often. Messages in English, imperative ("Add queue screen").
- Use a GitHub noreply address as git author.

## Scope
- Stay in `android/` and `linux/`. Do not change `tv/`, `desktop/`, `ios/`, `site/` without asking Milo and the maintainer: other apps depend on them.
- Subsonic API usage: see `tv/app/js/api.js` and `ios/Tonalo/`.
- Test against the mock server, not real data: `node tv/tools/mock_server.js 4599`.

## Never commit (public repo)
Passwords, tokens, keystores (`*.jks`, `*.keystore`), `google-services.json`, `local.properties`, real server addresses, private domains or IPs, real emails, real names or device names (also not in screenshots or test data). Check `git diff --cached` before every commit.

## Security
- Credentials only in the Android Keystore, never in plain preferences or logs.
- https for credentials; http only inside the home network. Never forward credentials on a redirect to another host.
- No third-party servers, SDKs, analytics or tracking.
- Show server data as plain text only.

## Texts and style
- Code, comments, commits in English. App texts in English and German (`values/strings.xml`, `values-de/strings.xml`). No emojis in published texts. The shared-listening feature is called "Jukebox", never "Jam".

## Honesty
- Never say something works that was not tested. Say whether it ran on an emulator or a real device.
- Work in small steps. If unsure, ask Milo instead of restructuring things.
