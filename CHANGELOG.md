# Changelog

All notable changes to GrokGauge. Versions follow [Semantic Versioning](https://semver.org/);
dates are when the version was built.

## [Unreleased]

### Fixed
- **The gear's first click really opens its menu now, and a click outside closes the dropdown.** 0.9.3's
  gear menu flashed open and closed on the first click, and until then a click elsewhere didn't close the
  dropdown. The cause was activation: GrokGauge is a menu bar app, and opening the dropdown only *requested*
  activation after it appeared (`NSApp.activate()`), so the app wasn't active and the dropdown wasn't key. The
  first click inside then activated the app, and that activation dismissed the menu. The dropdown now
  activates GrokGauge before it appears and becomes key straight away; the gear waits for activation to land
  before it opens its menu; and a click in another app or on the desktop always closes the dropdown, even if
  activation is refused.

## [0.9.3] - 2026-10-19

### Fixed
- **The gear button opens its menu on the first click.** In 0.9.2 the first click on the gear only made the
  dropdown the active window (it becomes key a moment after it opens), so Settings… / Quit GrokGauge needed a
  second click. The gear is now an AppKit button that accepts that first click and opens the menu itself.
  Settings… (⌘,) and Quit GrokGauge (⌘Q) work as before.
- **Usage history now reaches every Mac when settings sync through a subfolder.** History followed the
  settings-sync folder first, so a Mac whose settings sync through, say, `MacSyncing/xAI` wrote its history
  file into `MacSyncing/xAI/GrokGauge/history/` while the other Macs read `MacSyncing/GrokGauge/history/`,
  and neither side saw the other. When the settings-sync folder and the auto-found `MacSyncing` folder differ,
  GrokGauge now writes this Mac's file to both and reads both. A folder chosen for history is still used alone.
- History write failures no longer disappear: the last failed write (and a failed save of the local
  `history.json`) stays in Settings › Diagnostics › **History sync**, with the time, until a write succeeds.
  Diagnostics also lists every history folder in use and when this Mac's file was last written.

### Changed
- **Grok Bot on the shared pool.** When Grok Bot's own usage reading describes your shared SuperGrok weekly
  pool (its reset is within 2 minutes of the pool's and the percents are within 2 points), the Grok Bot ring
  shows **Grok Bot's share of that pool** (the GrokBot product in the usage reply), captioned
  "share of Grok pool", instead of repeating the Grok ring's number. Its pace, "On track" line, history and
  alerts use that share too, so one pool never alerts twice. The tooltip shows Grok Bot's own reading. Once
  a week is known to be shared it stays shared while the reset times match, so readings taken a few minutes
  apart don't flip the ring. When the two separate again, the ring goes back to Grok Bot's own allowance.
- **Clearer labels.** The Grok ring's caption is now "SuperGrok weekly pool" (its tooltip lists every
  product's share), the by-product card is "Grok pool by product", and its "Bot" row is now **Grok Bot**
  (your checkbox and position for it carry over). The menu bar tooltip and VoiceOver say when the Grok Bot
  number is a share of the pool.

### Added
- **Optional Cursor ring.** A third ring for the "Cursor" share of your Grok pool, from the same usage reply
  (no Cursor sign-in). Off by default: switch it on in Settings › Layout › **Rings** (or check
  "Cursor ring" in the section list). **With three rings**: keep ring size (the dropdown widens to 392 pt) or
  shrink the rings to fit the usual 320 pt. When the reply doesn't list Cursor, the ring says
  "Not in your Grok pool". The combined ring style includes it.
- A **Cursor** graph in "Last 7 days & pace" while the Cursor ring is on (Settings › Layout › History graphs).
- `--print-usage` and `--json` now report the rings as the dropdown shows them, including whether Grok Bot
  was detected on the shared pool, its share, and Cursor's share.
- History files keep working both ways: 0.9.2 reads 0.9.3 files (it ignores the new Cursor list and share
  tags), and 0.9.3 reads 0.9.2 files. When a Mac still on 0.9.2 shares a folder with a 0.9.3 Mac, its
  whole-pool Grok Bot readings after the switch are left out of the Grok Bot graph so one graph never mixes
  two measures; the switch itself isn't drawn as a reset.

## [0.9.2] - 2026-10-17

### Added
- **Usage history synced across your Macs.** The 7-day graphs now show readings from every Mac, not just
  this one. Each Mac writes only its own small file, `<sync folder>/GrokGauge/history/<machine-id>.json`
  (written atomically), and reads and merges everyone's. Usage is account-wide, so readings for the same
  product in the same 10-minute window are combined by taking the highest, never added; Grok and Grok Bot
  stay separate, entries older than the 8-day window are dropped, and a lone dip from one Mac's slightly
  older reading isn't drawn as a reset. The files hold only percentages, timestamps, an anonymous per-Mac id
  (a hash of the hardware UUID) and the Mac's name — never tokens or anything from `~/.grok`.
- The sync folder is the one Settings › Sync already uses; if none is set, GrokGauge looks for a `MacSyncing`
  folder in your cloud-drive folders (Google Drive, Insync, Dropbox…). Settings › Sync › **Usage history** has
  a **Sync history across Macs** switch (on by default; it does nothing until there's a folder), **Change…**,
  **Use iCloud Drive**, the number of Macs and the last sync, plus **Sync Now**. With no folder, history stays
  on this Mac exactly as before.
- GrokGauge watches the history folder (and re-reads it every minute and whenever the dropdown opens), so
  other Macs' readings appear on their own. Insync/Drive conflict copies are merged; partial, corrupt or
  foreign files are skipped (never deleted) and listed in Settings › Diagnostics › **History sync**, with the
  folder, the number of Macs and the last sync time.
- **Pick and sort the "Grok by product" rows.** Settings › Layout › **Grok by product** has a checkbox per
  product, a drag-to-reorder list (arrows and VoiceOver actions too), a **Sort** menu (My order, the default;
  Highest usage first, with ties in My order; Alphabetical) and **Reset**. Products xAI adds later appear at
  the end, shown. Unchecking every product hides the section. The choices are part of your settings, so they
  go into Export/Import and settings sync; settings from older versions get every product, the standard
  order and My order. **Reset Layout to Default** resets them too.
- **Service status row.** Two dots in the dropdown, right under the rings: **xAI** (`data.x.ai/status/summary.json`,
  falling back to the `status.x.ai/feed.xml` RSS if the summary fails or changes shape) and **Cursor**
  (`status.cursor.com/api/v2/summary.json`, the home of Grok Bot and Cloud Agents, which are named first when
  affected). Green "All systems normal"; orange for degraded, partial outage or maintenance; red for an outage;
  gray when a check failed. The text names what's affected (`xAI: Degraded: Imagine`,
  `Cursor: Outage: Cloud Agents`); the tooltip and VoiceOver label add the details and last check time;
  clicking opens status.x.ai or status.cursor.com. Checked about every 5 minutes and when the dropdown opens
  (at most every 30 s), backing off after failures (5, 10, 20, then 30 min). Public pages only, no login.
- Settings › Layout: a **Service status** section (on by default, reorderable) with **xAI** and **Cursor**
  switches and an optional, off-by-default notification when a service goes from normal to an outage. The
  choices sync with your other settings; settings from older versions get both dots on and the row placed
  after the rings. Settings › Diagnostics › **Service status** shows each source's last result, error and URL.
  New `--print-status` debug flag.
- **Guided Grok CLI setup.** When the Grok CLI isn't installed, the dropdown says so (instead of only
  "run `grok login`", which fails with "command not found") and offers **Copy install command**
  (`curl -fsSL https://x.ai/cli/install.sh | bash`, xAI's official installer), **Install in Terminal…**
  (asks first, then runs it in Terminal) and **Open Terminal**. Once installed it shows **Sign in to Grok**
  with **Copy “grok login”** and the `~/.grok/bin/grok login` fallback. GrokGauge re-checks when the dropdown
  opens and every few seconds while setup is pending, and switches to usage as soon as `auth.json` appears.
  Diagnostics and `--print-usage` show the same status.
- **What's new from xAI** section in the dropdown: the 4 newest items from xAI news (x.ai sitemap), the API
  release notes (docs.x.ai), Grok CLI updates (x.ai/cli/stable vs. the installed CLI, with the `grok update`
  command and a Copy button; GrokGauge never runs it), the Grok and Grok Bot iPhone apps (Apple's public
  lookup) and Grok Bot for Mac (its installed version, with Open). Unread dots, **Mark all read**, links to
  @xai and @grok on X. The first check marks everything already out as read. No login or API key.
- Settings › **What's New** tab: show the section, per-source switches, check interval (6/12/24 h; Grok CLI
  every 2 h), optional notifications (off by default, one summary per check), Check Now, Mark All Read.
  Choices sync with your other settings; read marks stay on this Mac.
- Settings › Diagnostics lists each What's new source with its status, last check and last error.
- **Support GrokGauge:** a Tip via PayPal button in Settings › About, a **Support GrokGauge…** link in the
  dropdown footer and the app menu, a PayPal badge in the README, and `.github/FUNDING.yml` (GitHub's
  Sponsor button).

### Changed
- The dropdown's gear opens a **Settings… / Quit GrokGauge** menu, like ClipGauge.

### Fixed
- The dropdown could be taller than the screen (graphs cut off, no scrolling). It's now capped to the screen;
  the middle sections scroll.

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
- Settings › About shows who makes GrokGauge: the retroCombs logo, a **YouTube: @retroCombs-Tech** button and a
  contact address (retroCombs@icloud.com). The README, issue chooser, CONTRIBUTING and release notes point there too.
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

[0.9.3]: https://github.com/stevencombs/GrokGauge/compare/v0.9.2...v0.9.3
[0.9.0]: https://github.com/stevencombs/GrokGauge/compare/v0.3.0...v0.9.0
[0.3.0]: https://github.com/stevencombs/GrokGauge/releases/tag/v0.3.0
[0.2.0]: https://github.com/stevencombs/GrokGauge/commit/e64bec4
[0.1.0]: https://github.com/stevencombs/GrokGauge/commit/1276387
