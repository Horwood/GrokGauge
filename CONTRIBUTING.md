# Contributing to GrokGauge

Thanks for helping! GrokGauge is a small, dependency-free macOS menu bar app. Bug reports,
fixes and focused features are all welcome.

## Before you start

- **Bugs:** open an issue with the bug template and paste the report from
  **Settings › Diagnostics › Copy Report**. It never contains tokens, emails, account ids or paths.
- **Features:** open a feature request first for anything bigger than a small fix, so we can agree on the shape.

## Building

Requirements: macOS 14 or later and Swift 5.10+ (the Xcode Command Line Tools are enough; Xcode is optional).

```sh
./scripts/test.sh                      # unit tests (swift-testing)
./scripts/build-app.sh                 # dist/GrokGauge.app + zip (universal by default)
ARCHS=arm64 ./scripts/build-app.sh     # faster single-arch build
dist/GrokGauge.app/Contents/MacOS/GrokGauge --print-usage      # one fetch, never prints tokens
dist/GrokGauge.app/Contents/MacOS/GrokGauge --render-preview /tmp/gg --demo   # screenshots with sample data
```

Note: recent SDKs implement SwiftUI's `@State` as a macro, and the Command Line Tools don't ship
that plugin. Use `@ViewState` (a typealias for `SwiftUI.State` in `Palette.swift`) instead.

## Code layout

- `Sources/GrokGaugeCore` - Foundation-only logic: auth file handling and renewal, the billing request,
  parsing, Grok Bot's cache reader, settings model and sync, colors, pace, history, update check.
  Everything here is unit tested.
- `Sources/GrokGauge` - the AppKit/SwiftUI app: status item, dropdown, Settings window, notifications.
- `Tests/GrokGaugeCoreTests` - swift-testing suites.

## Rules that keep users safe

These are non-negotiable in reviews:

1. **Tokens go only where they belong.** The Grok access token goes only to the billing endpoint, and the
   refresh token only to auth.x.ai's token endpoint, over ephemeral sessions that refuse redirects.
   Never log, print or write tokens anywhere else (including test output, previews and diagnostics).
2. **Grok Bot is read-only.** GrokGauge reads Grok Bot's local usage cache and nothing else. Don't read its
   login, its Keychain items, or modify any of its files.
3. **Only preferences sync.** `settings.json` must never contain tokens, usage numbers or history.
4. **No third-party dependencies** and no analytics. The only other network call is the optional,
   unauthenticated GitHub "latest release" check.

## Pull requests

- Keep PRs focused; add or update tests for Core changes.
- `./scripts/test.sh` passes and `./scripts/build-app.sh` builds with no new warnings.
- Update `CHANGELOG.md` (Unreleased section) and the README if behavior changes.
- UI changes: attach before/after images (`--render-preview DIR --demo` makes them without screen recording).

By contributing you agree your work is released under the MIT License.
