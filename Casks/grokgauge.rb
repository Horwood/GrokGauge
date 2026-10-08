# Template for a future tap: github.com/stevencombs/homebrew-tap  ->  Casks/grokgauge.rb
# After tagging a release, set `version` and replace `sha256` with the value from
# GrokGauge-<version>.zip.sha256 attached to that GitHub release.
cask "grokgauge" do
  version "0.3.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/stevencombs/GrokGauge/releases/download/v#{version}/GrokGauge-#{version}.zip"
  name "GrokGauge"
  desc "Menu bar gauge for SuperGrok and Grok Bot weekly usage"
  homepage "https://github.com/stevencombs/GrokGauge"

  depends_on macos: ">= :sonoma"

  app "GrokGauge.app"

  uninstall quit: "com.retrocombs.GrokGauge"

  zap trash: [
    "~/Library/Preferences/com.retrocombs.GrokGauge.plist",
  ]

  caveats <<~EOS
    GrokGauge reads the login created by the Grok CLI. If you haven't already:
      grok login

    GrokGauge is ad-hoc signed (not notarized). If macOS blocks it on first launch, run:
      xattr -dr com.apple.quarantine "#{appdir}/GrokGauge.app"
  EOS
end
