## What does this change?

<!-- A short description, and the issue it fixes (e.g. "Fixes #12"). -->

## How was it tested?

- [ ] `./scripts/test.sh` passes
- [ ] `./scripts/build-app.sh` builds with no new warnings
- [ ] Tried it in the running app (describe below)

## Screenshots

<!-- For UI changes: before/after. `GrokGauge --render-preview DIR --demo` renders them without screen recording. -->

## Safety checklist

- [ ] No token, email, or account id is logged, printed, written, or sent anywhere new
- [ ] Grok Bot's files and login are still only read (its usage cache), never modified
- [ ] Nothing besides preferences goes into the synced `settings.json`
- [ ] No new third-party dependencies
- [ ] CHANGELOG.md / README updated if behavior changed
