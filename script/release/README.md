# Release artifacts and Cask formula

This directory ships templates used when cutting a TokenBar release. It is
**not** the homebrew tap itself — the tap lives in its own repository (e.g.
`Bububuger/homebrew-tap`) so that `brew install --cask` can resolve it.

## Files

| Path | Purpose |
|---|---|
| `Casks/tokenbar.rb` | Cask formula template. Copy into the tap repo and update `version` + `sha256` after each release. |

## Release flow

Follow the authoritative [release runbook](../../docs/runbooks/release.md) for
prerequisites, local acceptance, committing version changes, tagging, publishing
assets, and updating the independent Homebrew tap.

From the repository root, `script/release.sh <version>` builds
`dist/TokenBar-<version>.dmg` and prints its SHA-256. It embeds the CLI and uses
ad-hoc signing; it does not archive, notarize, publish, or update this Cask template.
Update both `version` and `sha256` in `Casks/tokenbar.rb` with the actual release
values, commit the reviewed version changes before tagging, then follow the
runbook's publication order. Replace the existing SHA value; the template already
contains a release checksum, not a placeholder.

## What end users get

After `brew install --cask <tap>/tokenbar`:

- `/Applications/TokenBar.app` — the menu-bar app
- `$(brew --prefix)/bin/tbar` — the CLI (symlinked from
  `TokenBar.app/Contents/MacOS/tbar` by the `binary` stanza in the Cask)

Both come from the same DMG, with one install command and one uninstall:

```bash
brew install --cask <tap>/tokenbar
brew uninstall --cask <tap>/tokenbar      # also removes the symlinked tbar
```

## Why the CLI lives inside the .app bundle

The alternative is shipping `tbar` as a separate Homebrew **formula** (built
from source), but that means:

1. End users have to install Xcode CLT to build it, OR
2. We have to ship bottles for every macOS × arch combination.

Embedding the prebuilt CLI inside the existing signed .app bundle dodges
both — one DMG covers both surfaces, and uninstall is symmetric.
