<p align="center">
  <img src="docs/icon.png" width="128" alt="GrokGauge icon">
</p>

<h1 align="center">GrokGauge</h1>

<p align="center">
  Your SuperGrok and Grok Bot usage, at a glance, in the macOS menu bar.<br>
  <sub>Native Swift · macOS 14+ · Apple silicon &amp; Intel · MIT licensed</sub>
</p>

<p align="center">
  <img src="docs/menubar-demo.png" width="480" alt="GrokGauge in the menu bar: the higher of the two percents (86%), both percents (G 42% · B 86%), and a red 95%">
</p>

> **Unofficial.** GrokGauge is a community project by [retroCombs](https://www.retrocombs.com).
> It is not made, endorsed, or supported by xAI, or by Anysphere, the maker of the Grok Bot app.
> "Grok" and "SuperGrok" are trademarks of xAI. GrokGauge reads undocumented data sources that
> can change without notice.

## What it does

GrokGauge tracks two weekly limits side by side:

- **Grok.** SuperGrok plans share **one usage pool** across Chat, Imagine, Voice, Build, and the
  API. It resets **every 7 days** on your account's own schedule.
- **Grok Bot.** If you use the [Grok Bot](https://cursor.com/bot) desktop app, its **weekly usage**
  (the number on Grok Bot's *Settings › Usage & Billing* screen) has its own limit and its own reset time.

Features:

- **Menu bar meter.** A small Grok-style glyph plus a percent, color-coded **green** up to 80%,
  **orange** from 81–90%, and **red** above 90%. By default it shows the **higher** of the two
  numbers. Turn on **Show both percentages in menu bar** to see `G 0% · B 9%` instead, each colored separately.
- **Two ring gauges.** Grok on the left, Grok Bot on the right, with the same colors.
- **Reset times.** Days until reset, a live countdown, and the exact reset day and time in your
  time zone. When Grok and Grok Bot reset at different times you get one clearly labeled line for each.
- **Per-product breakdown** of the Grok pool: Chat, Imagine, Voice, Build, and API.
- **Extra Usage Credits.** Your prepaid Grok credit balance (and on-demand spend, if you've enabled it).
- **Heads-up notifications** when Grok or Grok Bot crosses 80% and 90%, once per week for each.
- **Refresh now**, last-updated time, and automatic refresh every 15 minutes (and after wake).
- **Launch at login** toggle (uses macOS's built-in Login Items).
- **Open Grok** (grok.com in your default browser) and **Open Grok Bot** (if installed) right from the menu.

<p align="center">
  <img src="docs/popover-dark-demo.png" width="300" alt="GrokGauge dropdown, dark mode">
  &nbsp;&nbsp;
  <img src="docs/popover-light-demo.png" width="300" alt="GrokGauge dropdown, light mode">
</p>
<p align="center"><sub>Screenshots use sample data (Grok 42%, Grok Bot 86%).</sub></p>

## Requirements

- macOS 14 Sonoma or later
- A SuperGrok subscription
- The **Grok CLI** (Grok Build), signed in once:

  ```sh
  grok login
  ```

  GrokGauge uses the login the CLI saves in `~/.grok/auth.json` and **renews it automatically**
  the same way the CLI does, so you stay signed in without running `grok login` again. You only
  need to sign in again if xAI revokes the login (for example after a password change or
  "sign out everywhere"); the menu then shows **"Run `grok login` to reconnect."**
- *Optional:* the **Grok Bot** desktop app, signed in. GrokGauge shows the Grok Bot ring only
  when Grok Bot is installed.

## Install

### Homebrew (recommended)

```sh
brew install --cask stevencombs/tap/grokgauge
```

This installs **GrokGauge.app** into `/Applications`. Update it with `brew upgrade --cask grokgauge`.
Remove it with `brew uninstall --cask grokgauge` (add `--zap` to also delete its preferences).

GrokGauge is ad-hoc signed, not notarized by Apple. So that macOS doesn't block the first launch,
the cask ([stevencombs/homebrew-tap](https://github.com/stevencombs/homebrew-tap)) removes the
download quarantine flag from `GrokGauge.app`, and only that app, right after installing it.

### Manual

1. Download `GrokGauge-<version>.zip` from the [latest release](https://github.com/stevencombs/GrokGauge/releases/latest).
2. Unzip it and drag **GrokGauge.app** into `/Applications` (or `~/Applications`).
3. Open it. Look for the gauge in your menu bar.

GrokGauge releases are ad-hoc signed, not notarized by Apple, so the first time you open a
manually downloaded copy, macOS says it can't verify the app. Either:

- open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to
  GrokGauge (recent macOS versions no longer offer a right-click **Open** bypass), or
- remove the quarantine flag in Terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/GrokGauge.app
  ```

Each release lists the zip's SHA-256 so you can check your download with `shasum -a 256`.

### First run

1. Click the gauge in the menu bar to open the dropdown.
2. When macOS asks, **allow notifications** so you get the 80% and 90% alerts.
3. Turn on **Launch at login** in the dropdown if you want GrokGauge to start with your Mac.
4. Use **Refresh now** any time; otherwise it updates itself every 15 minutes.

### Using it on several Macs

Run `brew install --cask stevencombs/tap/grokgauge` and `grok login` on each Mac. Settings are per-Mac; there's nothing to sync.

## Privacy

### Grok

- Your Grok tokens **never leave your Mac** except to two xAI hosts, over HTTPS:
  - the access token goes to xAI's usage endpoint (`cli-chat-proxy.grok.com`), and
  - the refresh token goes to xAI's sign-in server (`auth.x.ai`), only when the login needs renewing.
  They go nowhere else. GrokGauge refuses to send them to any other host.
- **GrokGauge writes to `~/.grok/auth.json`.** When it renews your login it saves the new tokens
  back into that file so the Grok CLI keeps working with them. It changes only the token fields
  of that one login (`key`, `refresh_token`, `expires_at`, `create_time`), keeps every other field
  and the file's owner-only (`0600`) permissions, and writes atomically while holding the same
  `auth.json.lock` the CLI uses, so the two never renew at the same moment.
- Tokens are never logged, printed, or copied anywhere else.
- Requests use an ephemeral session (no cookies, no cache) and refuse redirects, so tokens
  can't be forwarded to another host.

### Grok Bot

- GrokGauge **makes no network requests for Grok Bot** and uses **no Grok Bot token, password, or
  Keychain item**. It never sends Grok Bot data anywhere.
- It only **reads** two small files that Grok Bot itself writes, both inside
  `~/Library/Application Support/Grok Bot/sand-client-persistence/`:
  - the signed-in account marker (storage key `sand.client.slice.client-meta.account-slot`), and
  - that account's weekly-usage cache (storage key
    `sand.client.slice.account.<account>.weekly-usage.cache`): the percent used, the next reset
    time, and when Grok Bot last checked.

  Grok Bot names each file after its storage key (base32-encoded, plus `.blob`). Neither file
  contains a credential.
- GrokGauge never writes to, renames, or deletes anything in Grok Bot's folder. It doesn't touch
  Grok Bot's login or its encrypted secrets (`sand-secrets.json` and the "Grok Bot Safe Storage"
  Keychain item), and it never talks to Grok Bot's servers.

### Both

- No analytics, no telemetry, no third-party servers.

## How it works (and the fine print)

GrokGauge calls the same **unofficial** billing endpoint the Grok CLI uses for its `/usage` view:

```
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Authorization: Bearer <token from ~/.grok/auth.json>
```

and reads `config.creditUsagePercent`, `config.currentPeriod`, `config.productUsage`, and the credit
balances. xAI doesn't document this endpoint and can change it at any time, which could break
GrokGauge until it's updated. When xAI omits `creditUsagePercent` (it does right after a reset,
since zero values are dropped), GrokGauge shows 0%.

### Grok Bot

The Grok Bot app checks your weekly usage with its own server and caches the result on disk (see
[Privacy](#grok-bot)). GrokGauge re-reads that cache every 2 minutes, whenever you open the
dropdown, and on every Grok refresh. That means:

- The Grok Bot number is **as fresh as Grok Bot's last check**. The ring shows "as of 4:28 PM" so
  you know how old it is. Grok Bot updates the cache on its own schedule, and only while it's
  running. Opening Grok Bot's *Usage & Billing* screen is a quick way to get a fresh number.
- If the cached reading has expired (Grok Bot keeps it for about a day) or its week has already
  reset, the ring goes gray and says **"Open Grok Bot to update."** If Grok Bot is signed out or
  hasn't checked yet, it says **"Open Grok Bot to reconnect."** Only the Grok Bot ring changes;
  Grok keeps working.
- Percentages are rounded the same way Grok Bot rounds them (anything between 0 and 1% shows as 1%).
- Grok Bot's cache format is internal to Grok Bot and may change in a future version. If it does,
  the ring says "Couldn't read usage" until GrokGauge is updated.

### Staying signed in

Grok CLI access tokens last a few hours. GrokGauge renews the login when the access token is
within an hour of expiring, or right away if the usage endpoint rejects it, then retries the usage
request once. Renewal uses the same OpenID Connect refresh flow as the official Grok CLI
([xai-org/grok-build](https://github.com/xai-org/grok-build), `xai-grok-login`):

1. Take the CLI's lock (`~/.grok/auth.json.lock`) and re-read `auth.json`. If the CLI already
   renewed the token, use that one and stop.
2. Look up the token endpoint from `https://auth.x.ai/.well-known/openid-configuration`.
3. `POST https://auth.x.ai/oauth2/token` with `grant_type=refresh_token`, the stored
   `refresh_token`, and the stored `oidc_client_id` (plus `principal_type`/`principal_id` when present).
4. Save the new access token, the rotated refresh token (if xAI sent one), and the new expiry back
   into `auth.json`, then release the lock.

If xAI rejects the refresh token, GrokGauge stops and asks you to run `grok login`. If auth.x.ai
is just unreachable, it keeps using the current token while it's still valid and tries again later.

### Debug flags

Want the raw numbers? Run the app binary with a debug flag. None of them print your tokens:

```sh
/Applications/GrokGauge.app/Contents/MacOS/GrokGauge --print-usage   # Grok + Grok Bot; or --json
/Applications/GrokGauge.app/Contents/MacOS/GrokGauge --refresh-now   # renew the login now; prints expiry times
```

## Build from source

You only need the Xcode **Command Line Tools** (`xcode-select --install`); the full Xcode app is optional.

```sh
git clone https://github.com/stevencombs/GrokGauge.git
cd GrokGauge
./scripts/test.sh            # unit tests
./scripts/build-app.sh       # -> dist/GrokGauge.app and dist/GrokGauge-<version>.zip
open dist/GrokGauge.app
```

`build-app.sh` compiles a universal (arm64 + x86_64) release binary with Swift Package Manager,
assembles the `.app` bundle, ad-hoc signs it, and zips it. Set `ARCHS=arm64` for an Apple
silicon-only build, or `CODESIGN_IDENTITY="Developer ID Application: …"` to sign with your own
certificate.

### Releasing

1. Bump `VERSION`, commit, then tag: `git tag -a v1.2.3 -m "GrokGauge 1.2.3" && git push origin v1.2.3`.
2. The **Release** GitHub Action runs the tests, builds the universal app, and attaches
   `GrokGauge-<version>.zip` (and its `.sha256`) to a GitHub release.
3. In [stevencombs/homebrew-tap](https://github.com/stevencombs/homebrew-tap), update `version`
   and `sha256` in `Casks/grokgauge.rb`, then copy that file to `Casks/grokgauge.rb` here so the
   two stay in sync. Check it with `brew audit --cask --strict --online stevencombs/tap/grokgauge`.

### Project layout

```
Sources/GrokGaugeCore/   auth.json + token renewal, the billing request, the Grok Bot cache reader (Foundation only)
Sources/GrokGauge/       menu bar app (AppKit + SwiftUI), notifications, login item, debug CLI
Tests/                   swift-testing unit tests
scripts/                 build-app.sh, test.sh, assets/make-icon.py
Resources/               Info.plist template, AppIcon.icns
Casks/grokgauge.rb       Copy of the cask in stevencombs/homebrew-tap
```

## Credits

Created by **Steven Combs** ([retroCombs](https://www.youtube.com/@retroCombs)) and built together with
**Grok Bot**, Steven's AI assistant, which wrote the code, tests, and docs to his spec.


Endpoint details were cross-checked against the open-source
[pi-grok-usage](https://github.com/apoapostolov/pi-grok-usage),
[CodexBar](https://github.com/steipete/CodexBar), and
[OmniRoute](https://github.com/diegosouzapw/OmniRoute) projects. The GrokGauge glyph is an original
drawing and isn't xAI's logo.

## License

[MIT](LICENSE) © 2026 Steven Combs (retroCombs)
