# Release artifacts and Cask formula

This directory ships templates used when cutting a TokenBar release. It is
**not** the homebrew tap itself — the tap lives in its own repository (e.g.
`Bububuger/homebrew-tap`) so that `brew install --cask` can resolve it.

## Files

| Path | Purpose |
|---|---|
| `Casks/tokenbar.rb` | Cask formula template. Copy into the tap repo and update `version` + `sha256` after each release. |

## Release flow

```bash
# 1. Build DMG (also embeds `tbar` CLI into the .app — see script/release.sh)
./script/release.sh 1.2.0

#    Output looks like:
#      File          : dist/TokenBar-1.2.0.dmg  (12M)
#      sha256        : abcd1234…
#      Embedded CLI  : TokenBar.app/Contents/MacOS/tbar

# 2. Tag and push
git tag v1.2.0 && git push origin v1.2.0

# 3. Upload dist/TokenBar-1.2.0.dmg to the GitHub Release for v1.2.0.

# 4. Bump the tap's Cask formula:
#      cd /path/to/homebrew-tap
#      cp /path/to/tokenbar/script/release/Casks/tokenbar.rb Casks/tokenbar.rb
#      sed -i '' 's/REPLACE_WITH_DMG_SHA256_FROM_RELEASE_SH/abcd1234…/' Casks/tokenbar.rb
#      sed -i '' 's/version "[^"]*"/version "1.2.0"/' Casks/tokenbar.rb
#      git commit -am "tokenbar 1.2.0" && git push
```

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
