# GrokGauge Roadmap

Here's what's coming to GrokGauge and what's being considered. Plans can change, and nothing here has a
promised date.

## Next update (planned)

- **An optional Cursor usage ring.** xAI's usage data now reports a "Cursor" share of the Grok pool. You'll be
  able to show it as a third ring next to Grok and Grok Bot, with a setting to keep the rings at their current
  size or shrink them so all three fit.
- **Fix: the gear button needs two clicks.** One click will open the Settings / Quit menu.

## Under consideration

- **Clearer Grok Bot labels.** It should be easier to tell Grok Bot's own weekly allowance (its ring) apart from
  Grok Bot's share of the Grok pool (the "Bot" row in "Grok by product").
- **JSON usage export to a synced folder,** so widgets and your other devices can read your current usage.
- **A count of running Cursor agents.** On hold until Cursor offers a read-only or Projects API. GrokGauge only
  uses public or documented data and never scrapes logins.

## Toward 1.0

- Developer ID signing and Apple notarization, so GrokGauge opens without Gatekeeper workarounds.
- Then submitting GrokGauge to the official Homebrew cask catalog.

## Recently shipped

**0.9.2:** usage history synced across your Macs, xAI and Cursor service status dots, a "What's new from xAI"
section, guided Grok CLI setup, and picking and sorting the "Grok by product" rows. See
[CHANGELOG.md](CHANGELOG.md) for every release.

## Got an idea?

Suggestions and bug reports are welcome in [GitHub Issues](https://github.com/stevencombs/GrokGauge/issues).

---

GrokGauge is an unofficial community project. It is not made, endorsed, or supported by xAI, or by
Anysphere, the maker of Cursor and the Grok Bot app. "Grok" and "SuperGrok" are trademarks of xAI.
