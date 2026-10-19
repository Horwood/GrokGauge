cask "grokgauge" do
  version "0.9.4"
  sha256 "189f5d771b6b10612d04fcfd2e65509406d62765163b2d413617db7f1d366423"

  url "https://github.com/stevencombs/GrokGauge/releases/download/v#{version}/GrokGauge-#{version}.zip"
  name "GrokGauge"
  desc "Menu bar gauge for SuperGrok and Grok Bot weekly usage"
  homepage "https://github.com/stevencombs/GrokGauge"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "GrokGauge.app"

  # GrokGauge is open source but ad-hoc signed (not notarized), so macOS would block
  # the first launch. Clear the download quarantine flag on this one app only.
  postflight_steps do
    on_macos do
      run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/GrokGauge.app"]
    end
  end

  uninstall quit: "com.retrocombs.GrokGauge"

  zap trash: [
    "~/Library/Application Support/GrokGauge",
    "~/Library/Preferences/com.retrocombs.GrokGauge.plist",
  ]

  caveats <<~EOS
    GrokGauge is ad-hoc signed, not notarized by Apple. This cask removed the
    download quarantine flag from #{appdir}/GrokGauge.app so it opens normally.

    GrokGauge reads the login created by the Grok CLI. If you haven't already:
      grok login

    Grok Bot usage appears automatically if the Grok Bot app is installed.
  EOS
end
