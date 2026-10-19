# GrokGauge Roadmap

Here's what's coming to GrokGauge and what's being considered. Plans can change, and nothing here has a
promised date.

## Under consideration

- **JSON usage export to a synced folder,** so widgets and your other devices can read your current usage.
- **A count of running Cursor agents.** On hold until Cursor offers a read-only or Projects API. GrokGauge only
  uses public or documented data and never scrapes logins.

## Toward 1.0

- Developer ID signing and Apple notarization, so GrokGauge opens without Gatekeeper workarounds.
- Then submitting GrokGauge to the official Homebrew cask catalog.

## Recently shipped

**0.9.4:** the gear menu opens on the first click and stays open, and a click outside the dropdown closes it
again (GrokGauge now becomes the active app as the dropdown opens).

**0.9.3:** an optional Cursor ring (its share of the Grok pool) with a keep-size or fit-to-width setting, the
Grok Bot ring showing Grok Bot's share when it's on the shared Grok pool, clearer pool labels, a one-click
gear menu, and history sync that reaches every Mac even when settings sync through a subfolder.

**0.9.2:** usage history synced across your Macs, xAI and Cursor service status dots, a "What's new from xAI"
section, guided Grok CLI setup, and picking and sorting the "Grok by product" rows. See
[CHANGELOG.md](CHANGELOG.md) for every release.

## Got an idea?

Suggestions and bug reports are welcome in [GitHub Issues](https://github.com/stevencombs/GrokGauge/issues).

---

GrokGauge is an unofficial community project. It is not made, endorsed, or supported by xAI or Cursor. "Grok" and "SuperGrok" are trademarks of xAI.
