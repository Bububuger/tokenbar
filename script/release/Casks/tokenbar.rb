# Homebrew Cask formula for TokenBar.
#
# This file is a TEMPLATE — copy it into your homebrew tap repo
# (e.g. `homebrew-tap/Casks/tokenbar.rb`) after each release, and replace the
# `version` and `sha256` fields with the values printed by `script/release.sh`.
#
# Why this Cask installs both the app AND the `tbar` CLI:
#   release.sh builds the TokenBarCLI Xcode target and copies the resulting
#   binary into TokenBar.app/Contents/MacOS/tbar. The `binary` stanza below
#   tells Homebrew to symlink that path into /opt/homebrew/bin/tbar (or
#   /usr/local/bin/tbar on Intel), so users get the CLI on $PATH for free.
#
# Install (single fully-qualified line — auto-taps if not yet tapped):
#   brew install --cask <your-org>/tap/tokenbar
#
# Verify:
#   /Applications/TokenBar.app          ← menu-bar app
#   $(brew --prefix)/bin/tbar           ← CLI on $PATH
#   tbar schema --json | jq .schema.dataWindow

cask "tokenbar" do
  version "1.5.0"
  sha256 "07f1cf1380f130778f747a0627aba4b005aab17a62903e199a03ece70df8dec4"

  url "https://github.com/Bububuger/tokenbar/releases/download/v#{version}/TokenBar-#{version}.dmg"
  name "TokenBar"
  desc "Local-first menu-bar dashboard + CLI for AI coding token usage"
  homepage "https://github.com/Bububuger/tokenbar"

  depends_on macos: ">= :ventura"
  livecheck do
    url :url
    strategy :github_latest
  end

  app "TokenBar.app"

  # Embedded CLI — symlinked onto $PATH so `tbar` works from any shell.
  # The path inside the .app is produced by script/release.sh step [4/6].
  binary "#{appdir}/TokenBar.app/Contents/MacOS/tbar"

  zap trash: [
    "~/Library/Application Support/com.javis.TokenBar",
    "~/Library/Preferences/com.javis.TokenBar.plist",
    "~/Library/Caches/com.javis.TokenBar",
    "~/Library/Saved Application State/com.javis.TokenBar.savedState",
  ]

  caveats <<~EOS
    TokenBar reads the local logs that Claude Code / Codex / Gemini / Cursor
    (etc.) already write under your home directory. Nothing is ever uploaded.

    Quick start:
      open -a TokenBar          # launch menu-bar app
      tbar schema --json        # confirm the CLI sees the same local index
      tbar summary --days 30    # 30-day usage breakdown
  EOS
end
