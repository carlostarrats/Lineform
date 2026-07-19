# GitHub and Sparkle Release Setup

Lineform's repository root is this `Lineform` app folder, not the parent `Lineform Bundle` folder.

## Before publishing — decide on the diagram-report backend (optional)

The Mermaid "Report this" feature (agent-reader unit 5) is code-complete but its live backend is
not wired; it fails safe until then ("Couldn't send. Saved locally."). Before a public release,
either **finish go-live** or **leave it as a safe no-op**:

- To go live: register a workers.dev subdomain (Cloudflare dashboard); create the private
  `carlostarrats/lineform-reports` repo + a fine-grained GitHub PAT (Issues read/write); set
  `DiagramReportService.endpoint` to `https://lineform-diagram-report.<subdomain>.workers.dev`;
  `cd worker && wrangler secret put GITHUB_TOKEN && wrangler deploy`; verify end-to-end.
- To ship without it: no action needed (it stays a graceful no-op), or hide the "Report this"
  affordance in `MarkdownPreviewRenderer.appendMermaidFallback`.

See `docs/superpowers/specs/2026-07-01-diagram-report-design.md`. This step is on branch
`diagram-report-golive`.

## Order of Work

0. Run the test gates (see "Test gates before building" below).
1. Create or connect the GitHub repo from this folder.
2. Generate Sparkle EdDSA keys and keep the private key in Keychain.
3. Build a signed release with `SPARKLE_PUBLIC_ED_KEY` set.
4. Package the app as a signed drag-to-Applications DMG.
5. Generate `docs/appcast.xml`.
6. Publish the DMG on GitHub Releases and commit `docs/appcast.xml`.
7. Confirm the public README and website download link point at the current release.

## Test gates before building

Two test plans exist (see `Claude.md` › Verification Commands). Before any release:

```sh
# Default plan — full pure suite (also what CI runs on every push):
xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
  -destination 'platform=macOS' -parallel-testing-enabled NO

# Hosted plan — the quarantined window-motion tests. NOT run by CI or the default
# suite, so a release is the checkpoint that must run them. Quiet machine, Xcode quit.
xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
  -destination 'platform=macOS' -parallel-testing-enabled NO -testPlan LineformHosted
```

The hosted plan is load-sensitive and its test host can crash at teardown (known,
documented in `Claude.md`; never affects the app). A hosted failure on a quiet
machine that reproduces in isolation is a real motion regression — do not ship it.

## GitHub Repo

```sh
gh repo create carlostarrats/Lineform --public --source . --remote origin --push
```

If the repo already exists:

```sh
git remote add origin https://github.com/carlostarrats/Lineform.git
git push -u origin main
```

The Sparkle feed URL compiled into Lineform is:

```text
https://raw.githubusercontent.com/carlostarrats/Lineform/main/docs/appcast.xml
```

The product website is:

```text
https://lineform-site.vercel.app
```

The public direct-download URL used by the website and README is:

```text
https://github.com/carlostarrats/Lineform/releases/latest/download/Lineform-1.1.0.dmg
```

## Sparkle Keys

Use Sparkle's `generate_keys` tool once. Save the public key as the `SPARKLE_PUBLIC_ED_KEY` build setting and keep the private key in the macOS Keychain for `generate_appcast`.

```sh
generate_keys
```

Local release build:

```sh
SPARKLE_PUBLIC_ED_KEY="PUBLIC_KEY_FROM_GENERATE_KEYS" packaging/build-release.sh
```

The release build script defaults to the Lineform Developer ID team and certificate:

```text
Developer ID Application: Carlos Tarrats (TV4QZT7A7X)
```

Before building an iCloud-enabled release, confirm the Apple Developer App ID for
`com.lineform.app` has iCloud enabled in **Include CloudKit support (requires
Xcode 6)** mode and that the iCloud container `iCloud.com.lineform.app` is
selected. Lineform uses the CloudDocuments service in that app-owned container.

Only the Release build carries the production container `iCloud.com.lineform.app`.
Debug builds (bundle id `com.lineform.app.debug`) intentionally ship **no** iCloud
entitlement (`Lineform/LineformDebug.entitlements` has none), so local/CI build
churn never touches the production container or its real user files, and the Debug
test host still launches under ad-hoc signing on CI. Do not add an iCloud
entitlement to Debug. Also do not run-then-delete locally built Release/Export
copies of `com.lineform.app` while signed into the production iCloud account —
that churn can make macOS treat the app as uninstalled and purge the production
container.

For public distribution, Xcode export also needs a Developer ID/Direct
distribution provisioning profile for `com.lineform.app` whose entitlements
include iCloud container environment support. The Xcode-managed development
profile is enough to verify iCloud Documents locally, but it is not a public
release signing profile.

Release signing must keep `Lineform/Lineform.entitlements` aligned with that
Direct profile, including `com.apple.application-identifier` set to
`TV4QZT7A7X.com.lineform.app` and `com.apple.developer.team-identifier` set to
`TV4QZT7A7X`. After installing a release candidate, check the launch log for
taskgated allowing `Mac Team Direct Provisioning Profile: com.lineform.app` and
for no iCloud Drive `application-identifier` entitlement warning.

Override `DEVELOPMENT_TEAM` or `CODE_SIGN_IDENTITY` only if the certificate changes.

**If the Developer ID certificate ever changes (renewal, dedupe, new Mac), the Direct
profile must be regenerated before the next release.** The profile embeds the specific
certificates it authorizes; an app whose restricted iCloud entitlements are signed by a
cert missing from `embedded.provisionprofile` passes `codesign --verify`, notarization,
and Gatekeeper, but is killed by AMFI at launch on every machine ("Lineform can't be
opened"). This shipped as 1.1.0 build 14. Refresh the profile headlessly with
`xcodebuild archive` + `-exportArchive` (method `developer-id`, signingStyle `automatic`,
`-allowProvisioningUpdates`) — it mints a new
`Mac Team Direct Provisioning Profile: com.lineform.app` under
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` — then update
`DEVELOPER_ID_PROFILE_PATH` in `packaging/build-release.sh`.

`packaging/build-release.sh` enforces two hard gates for this failure class: it fails
(exit 68) if the signing cert is not among the profile's `DeveloperCertificates`, and it
launches the packaged app once after signing (exit 69 if launchd refuses to spawn it),
before any DMG is built. Do not skip or remove these gates; `SKIP_LAUNCH_SMOKE_TEST=YES`
exists only for headless environments where the DMG will still be launch-tested manually.

If a DMG is needed before Sparkle signing is finalized, build with the placeholder key:

```sh
SPARKLE_PUBLIC_ED_KEY="SPARKLE_PUBLIC_ED_KEY" packaging/build-release.sh
```

That DMG is suitable for manual download testing, but **Check for Updates...** will show that updates are not configured until a real Sparkle public key and signed appcast are published.

Write the release notes (shown in the in-app updater's "What's New" pane):

Copy `docs/release-notes/TEMPLATE.html` to `docs/release-notes/Lineform-<version>.html`
— the name **must** match the DMG (`Lineform-1.3.0.dmg` → `Lineform-1.3.0.html`) — and write
a few **user-facing** highlights: what a person notices and benefits from, most useful first,
in plain language. It is not a changelog — skip internal refactors, renamed files, tests, and
docs. A small fix release can be a single honest line. Commit the file so notes are versioned
with the release.

`packaging/generate-appcast.sh` stages the matching file next to the DMG and Sparkle's
`generate_appcast` embeds it **inline** into `docs/appcast.xml` as the item's `<description>`
(via `--embed-release-notes`), so there is nothing extra to host and no app code change. If the
newest DMG has no matching notes file, the script prints a `[notes] WARNING …` and the update
would ship with an empty pane — add the file and re-run. Older DMGs (present only to build
deltas) do not need notes.

Generate the appcast after the signed DMG **and** the release-notes file exist:

```sh
DOWNLOAD_URL_PREFIX="https://github.com/carlostarrats/Lineform/releases/download/v1.1.0" \
  packaging/generate-appcast.sh dist
```

When hand-merging only the new top `<item>` into `docs/appcast.xml` (see the URL-prefix note
below), carry its `<description>…</description>` along — that is the embedded release notes.

Commit the generated `docs/appcast.xml` after each release so Sparkle can fetch the latest appcast over GitHub's HTTPS raw-content URL.

### Verify the update path before publishing

A fresh download launching is **not** proof that existing users can *update* — the update
mechanism is what bricked users in the 1.1.0 build 14 incident, and it has release-specific
failure modes a download test misses (a mismatched Sparkle EdDSA key pair → every update
rejected as "improperly signed"; a bad delta → failed/partial update). After generating the
appcast and before publishing, run:

```sh
LAUNCH_TEST=YES packaging/verify-update.sh          # interactive Mac
LAUNCH_TEST=NO  packaging/verify-update.sh           # headless CI (no window server)
```

It checks, for the top appcast entry: (1) the app's `SUPublicEDKey` matches the private
signing key, (2) the appcast `edSignature` is correct for the exact DMG bytes (so it must be
regenerated *after* `stapler staple`), and (3) every delta reconstructs the new build from the
real old build's DMG in `dist/` — verifying the resulting app's build number, code signature,
and (with `LAUNCH_TEST=YES`) that it launches. A delta whose old build has no DMG in `dist/`
is reported as `[skip]`, not silently passed. This is the closest headless proxy for the
Sparkle runtime flow; the runtime click-through itself (menu → download → install → relaunch)
still warrants one manual spot-check per release, since it can't be driven without UI/TCC.

## Bundled `lineform` command-line helper

`packaging/build-release.sh` builds the `lineform` CLI helper into the app after `xcodebuild`
and before signing, so it ships inside the DMG and is notarized with the app:

- It compiles `HelperTool/main.swift` + the shared `Lineform/CommandLineTool/LineformCommandLine.swift`
  with `swiftc` for `arm64` and `x86_64`, then `lipo`s them into `Contents/Helpers/lineform`
  (guarded by a universal-arch check, same as the app binary).
- The helper is signed (hardened runtime, timestamp) as the first item in the inside-out
  re-sign list, **without** any App Sandbox entitlement — it runs as an ordinary user process
  from the terminal and hands files to the app via `open`.
- No separate notarization step is needed: it is nested signed code inside the app, covered by
  the app's notarization submission.

The helper is only produced by this release script (not by plain `xcodebuild` Debug builds).
Users install it via **Lineform → Install Command Line Tool...** (symlink to
`/usr/local/bin/lineform`).

## Notarization

Store Apple notarization credentials once under the `lineform-notary` profile:

```bash
xcrun notarytool store-credentials "lineform-notary" \
  --apple-id "YOUR_APPLE_ID_EMAIL" \
  --team-id "TV4QZT7A7X"
```

Use an Apple app-specific password when prompted. Do not commit or share that password.

The DMG build script signs the compressed disk image with the Lineform Developer
ID Application identity by default. Set `DMG_CODE_SIGN_IDENTITY` only if the
certificate changes, or set it to an empty string for a local unsigned DMG that
will not be publicly released.

After building a Developer ID-signed DMG, notarize and staple it:

```bash
packaging/notarize-dmg.sh dist/Lineform-1.1.0.dmg
```

## DMG

The DMG script creates the same basic layout as the reference image: Lineform on the left, Applications on the right, and the repo-local background image at `packaging/assets/download-background.jpg`.

```sh
packaging/build-dmg.sh DerivedData/Release/Build/Products/Release/Lineform.app dist
```

The output path is:

```text
dist/Lineform-<version>.dmg
```

## Publish

Only upload the assets that belong to the new version. `dist/` keeps every
historical DMG so `generate_appcast` can build deltas, but the GitHub release
for a tag must contain only:

- the current full DMG, `dist/Lineform-<version>.dmg`
- the delta files generated for this release (`Lineform<build>-*.delta`)

Do **not** run `gh release upload <tag> dist/*.dmg`. Uploading the whole glob
staples old-version DMGs (1.0.4, 1.0.6, ...) onto the new release. The public
download and the marketing site then resolve to a stale DMG, because anything
that just picks "a `.dmg` on the latest release" can land on the wrong one.

```sh
VERSION="1.1.0"
gh release upload "v${VERSION}" \
  "dist/Lineform-${VERSION}.dmg" \
  dist/Lineform*-*.delta \
  --clobber
```

After publishing, the appcast's top `<item>` should be the only item whose
enclosures point at the new tag. Sparkle only ever updates clients forward to
the newest item, so older `<item>` entries and their full DMGs are not needed
and should not be re-hosted under the new tag.
