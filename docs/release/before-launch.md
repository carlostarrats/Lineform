# Before launch: held items

Lineform 1.9.0 brings the iPhone app and whole-document AI. We are testing the iPhone app in
TestFlight first, and the owner will make small user-experience changes that apply to both apps.
The items below are held on purpose until that work is finished. **Do every item before the App
Store release (Mac or iPhone) goes live.** The full release runbook is
[app-store-release.md](app-store-release.md).

Last updated: 2026-11-23.

## 1. Finish the experience first

- [ ] The owner's small user-experience changes, made on both apps (Mac and iPhone).
- [ ] After those changes, run the full Mac and iPhone test suites again and update the iPhone
      screenshots in [iphone-screenshots/](iphone-screenshots/) if any screen changed.

## 2. Privacy and public text

- [ ] Update the public privacy page on the marketing site. It must describe whole-document AI,
      Check for Updates, and announcements, on **both** apps. A draft is on the local branch
      `privacy-check-for-updates` (commit `d039980`) in `~/Developer/Lineform-marketing-privacy`.
      That branch is not pushed. Update the draft for any changes, then publish.
- [ ] Confirm that `web/privacy.html` in this repository and the App Store privacy answers
      (`.asc/privacy.json`) match the published page.

## 3. Translations

- [ ] A native speaker checks the agent-written translations in
      [../notes/translations-to-review.md](../notes/translations-to-review.md) for Spanish,
      French, German, Japanese and Simplified Chinese. This includes about 20 strings that only
      VoiceOver reads aloud.
- [ ] Translate any new text that the user-experience changes add.

## 4. Checks on a real iPhone (in TestFlight)

- [ ] The selection row next to the system edit menu.
- [ ] iCloud rename and delete, and that edits sync to the Mac.
- [ ] The keyboard in Preview.
- [ ] VoiceOver through the main flows; large Dynamic Type sizes.
- [ ] Reconnect, with a real file picked from Files.
- [ ] The Shortcuts actions: a temporary or Inbox file opens as a new note.
- [ ] The App Store review prompt.
- [ ] Whole-document AI: the confirm step above 1,500 words and the refusal above about 4,000
      words.

Caution: a TestFlight copy uses the production iCloud container. Real Lineform documents in iCloud
Drive appear on the phone, and edits sync back to the Mac.

## 5. Release order

- [ ] Ship Mac 1.9.0 first. Both apps share one listing, so they carry one version and build
      number. Never bump only one target.
- [ ] Do not publish an iPhone-only announcement (`"platforms": ["ios"]`) until most Mac users
      have a build that reads the `platforms` field (1.9.0 or later). Older Mac builds ignore the
      field and would show the entry.
- [ ] iPhone: archive, validate, upload, TestFlight, then submit, per the
      [iPhone section](app-store-release.md#iphone) of the runbook.

## 6. Repository hygiene (public repo)

- [ ] Decide whether to rewrite the old history entry for `.wrangler/cache/wrangler-account.json`
      (commits `0bc59f6`, `a6b0d26`, removed in `0a5bfc5`). It holds the owner's iCloud address and
      Cloudflare account ID. It is not a password or token. Rewriting needs a force-push.
- [ ] Before each release, scan the repository again for keys, tokens and personal addresses.

## Later (not needed for launch)

- Move the iPhone copies of the announcement and review-prompt stores into the shared package.
- Speed up the full restyle of the review overlay on very large documents.
