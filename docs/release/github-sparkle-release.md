# GitHub and Sparkle Release Setup

Lineform's repository root is this `Lineform` app folder, not the parent `Lineform Bundle` folder.

## Order of Work

1. Create or connect the GitHub repo from this folder.
2. Generate Sparkle EdDSA keys and keep the private key in Keychain.
3. Build a signed release with `SPARKLE_PUBLIC_ED_KEY` set.
4. Package the app as a drag-to-Applications DMG.
5. Generate `docs/appcast.xml`.
6. Publish the DMG on GitHub Releases and serve `docs/appcast.xml` with GitHub Pages.

## GitHub Repo

```sh
gh repo create carlostarrats/Lineform --public --source . --remote origin --push
```

If the repo already exists:

```sh
git remote add origin https://github.com/carlostarrats/Lineform.git
git push -u origin main
```

Enable GitHub Pages from the `main` branch using `/docs` as the Pages source. The Sparkle feed URL compiled into Lineform is:

```text
https://carlostarrats.github.io/Lineform/appcast.xml
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

Generate the appcast after the DMG exists:

```sh
DOWNLOAD_URL_PREFIX="https://github.com/carlostarrats/Lineform/releases/download/v1.0.0" \
  packaging/generate-appcast.sh dist
```

Commit the generated `docs/appcast.xml` after each release so GitHub Pages serves the latest appcast.

## DMG

The DMG script creates the same basic layout as the reference image: Lineform on the left, Applications on the right, and the repo-local background image at `packaging/assets/download-background.jpg`.

```sh
packaging/build-dmg.sh DerivedData/Release/Build/Products/Release/Lineform.app dist
```

The output path is:

```text
dist/Lineform-<version>.dmg
```
