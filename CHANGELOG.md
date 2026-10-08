# Changelog

All notable changes to GrokGauge. Versions follow [Semantic Versioning](https://semver.org/);
dates are when the version was built.

## [0.9.1] - 2026-10-08

### Fixed
- **"Grok returned an error (400)" that wouldn't clear.** GrokGauge kept one HTTP/3 connection open between
  refreshes; on 2026-10-08 the server instance behind one such connection answered every request with 400
  (after about 5 seconds) for roughly 14 minutes, while new connections got normal replies. Each refresh now
  uses its own short-lived connection, and a 400, 408, 421 or 5xx reply (or a dropped connection) is retried
  once right away on a brand-new connection. A 400 is also treated as temporary: GrokGauge keeps the last good
  reading and retries with backoff.
- Grok Bot's ring said "as of 5:38 PM" the next morning without saying which day. Readings from an earlier
  day now show the date ("as of Oct 7, 5:38 PM"); the tooltip has the full date and time.

### Added
- **Bar graph history:** "Last 7 days" shows one bar per day with the highest % reached that day, tinted with the
  level colors, weekday labels, today's bar highlighted and a small ↺ mark on the day the weekly allowance reset.
  VoiceOver reads each bar ("Thursday, October 8: peak 21 percent, weekly reset"). The pace line is unchanged.
- **Graph style** in Settings › Layout: Bars (default), Line (the 0.9.0 sparkline) or Area, picked from tiles that
  each show a small drawing of the style. Applies to both graphs.
- **Choose which history graphs appear:** "Grok history" and "Grok Bot history" toggles in Settings › Layout.
  Turning both off hides the "Last 7 days & pace" section (its own checkbox still works too).
- Settings › Diagnostics shows the server's own error message for errors other than 401/403
  (sanitized: no tokens, emails, ids or paths, at most 160 characters). `--print-usage` shows it too.

### Changed
- Settings saved by 0.9.0 are migrated automatically (new options start at their defaults) and the new options sync
  between Macs like the others.

## [0.9.0] - 2026-10-07

### Added
- **Settings window** (gear button in the dropdown, or ⌘,) with Layout, Menu Bar, Colors & Alerts,
  Sync, Diagnostics and About tabs. Every change applies immediately.
- **Layout:** show, hide and drag to reorder the dropdown sections and the action buttons;
  ring style side by side, stacked, or one combined ring that shows the higher percent.
- **Menu bar:** higher percent, both (G · B), Grok only, Grok Bot only, or the logo alone tinted by status;
  optional days-to-reset suffix (`10% · 5d`); option to hide the logo.
- **Colors & alerts:** a two-handle slider for the warning/critical levels (default 80/90) with numeric fields;
  custom colors through the macOS color picker, with a warning when two colors are hard to tell apart;
  a colorblind-friendly preset (Okabe–Ito). Colors apply to the rings, the menu bar and the product bars.
  Notifications follow the color levels unless you unlink them. Refresh interval 5/15/30/60 minutes.
  Launch at login moved here from the dropdown.
- **Sync:** keep settings in sync between Macs through a folder you already sync
  (`GrokGauge/settings.json`, newest change wins, watched for changes). Only preferences are synced,
  never logins, usage numbers or history. Export and import settings as JSON.
- **Diagnostics:** per-source status, last success, last error, login expiry time, app and macOS versions,
  and a "Copy report" button that never includes tokens, emails, account ids or file paths.
- **Updates:** optional daily check of GitHub's latest release; an "Update available" banner in the dropdown
  with a link to the release and the `brew upgrade --cask grokgauge` command. Nothing installs automatically.
- **History & pace:** 7-day sparklines from samples stored locally (`~/Library/Application Support/GrokGauge/history.json`,
  pruned after 8 days, never synced) and a pace projection ("On track" / "At this pace you'll hit 100% by Fri 3 PM").
- **Global keyboard shortcut** to open the dropdown (default ⌃⌥G, configurable).
- **Open X** button: opens the X app if installed, otherwise x.com (a shortcut only; no X data is read).
- VoiceOver labels and values for rings, bars, charts and buttons; Reduce Motion and Increase Contrast support.
- `--render-preview` also renders every Settings tab and the layout variants.
- CHANGELOG, CONTRIBUTING, issue and pull request templates.

### Changed
- Notifications fire when the displayed percent goes above a level (same rule as the colors),
  so exactly 80% no longer notifies with the default levels.
- Failed refreshes retry with exponential backoff. Right after wake or a network change, GrokGauge waits
  briefly and retries quietly instead of flashing an error.
- GitHub Actions moved to Node 24 versions (checkout v7, upload-artifact v7, action-gh-release v3).

### Fixed
- If xAI changes the shape of the billing reply (no `config`, no period), GrokGauge shows
  "xAI changed something" instead of 0%. A missing `creditUsagePercent` still means 0% when the rest of
  the reply is normal, and the ring now labels it "Inferred (none reported)".

## [0.3.0] - 2026-10-07

### Added
- Grok Bot weekly usage as a second ring, read-only from Grok Bot's own local cache
  (no network, never touches Grok Bot's login).
- Separate reset dates per pool; menu bar shows the higher percent, or both.
- Per-source notifications at 80% and 90%.
- Homebrew tap (`brew install --cask stevencombs/tap/grokgauge`).

## [0.2.0] - 2026-10-07

### Added
- Automatic renewal of the Grok CLI login through auth.x.ai's OIDC refresh flow, with atomic,
  lock-protected updates to `~/.grok/auth.json` and a backup before the first write.
- `--refresh-now` debug flag (prints expiry times only).

## [0.1.0] - 2026-10-07

### Added
- First release: SuperGrok weekly usage in the macOS menu bar with a green/orange/red ring,
  days to reset, per-product breakdown, Extra Usage Credits, notifications at 80% and 90%,
  launch at login, and Refresh now.
- `--print-usage`, `--json` and `--render-preview` debug flags.

[0.9.0]: https://github.com/stevencombs/GrokGauge/compare/v0.3.0...v0.9.0
[0.3.0]: https://github.com/stevencombs/GrokGauge/releases/tag/v0.3.0
[0.2.0]: https://github.com/stevencombs/GrokGauge/commit/e64bec4
[0.1.0]: https://github.com/stevencombs/GrokGauge/commit/1276387
