# GitHub and Sparkle Release Setup

Lineform's repository root is this `Lineform` app folder, not the parent `Lineform Bundle` folder.

## Order of Work

1. Create or connect the GitHub repo from this folder.
2. Generate Sparkle EdDSA keys and keep the private key in Keychain.
3. Build a signed release with `SPARKLE_PUBLIC_ED_KEY` set.
4. Package the app as a signed drag-to-Applications DMG.
5. Generate `docs/appcast.xml`.
6. Publish the DMG on GitHub Releases and commit `docs/appcast.xml`.
7. Confirm the public README and website download link point at the current release.

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
https://github.com/carlostarrats/Lineform/releases/latest/download/Lineform-1.0.7.dmg
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

If a DMG is needed before Sparkle signing is finalized, build with the placeholder key:

```sh
SPARKLE_PUBLIC_ED_KEY="SPARKLE_PUBLIC_ED_KEY" packaging/build-release.sh
```

That DMG is suitable for manual download testing, but **Check for Updates...** will show that updates are not configured until a real Sparkle public key and signed appcast are published.

Generate the appcast after the signed DMG exists:

```sh
DOWNLOAD_URL_PREFIX="https://github.com/carlostarrats/Lineform/releases/download/v1.0.7" \
  packaging/generate-appcast.sh dist
```

Commit the generated `docs/appcast.xml` after each release so Sparkle can fetch the latest appcast over GitHub's HTTPS raw-content URL.

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
packaging/notarize-dmg.sh dist/Lineform-1.0.7.dmg
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
