# Mirror of github.com/stevencombs/homebrew-tap/blob/main/Casks/grokgauge.rb (keep in sync).
cask "grokgauge" do
  version "0.9.7.1"
  sha256 "35e168e4cbbf938a9eaa25cfea8e3ac7fc108de4120fd05b224e59276ef5d9ad"

  url "https://github.com/stevencombs/GrokGauge/releases/download/v#{version}/GrokGauge-#{version}.zip"
  name "GrokGauge"
  desc "Menu bar gauge for SuperGrok and Grok Bot weekly usage"
  homepage "https://github.com/stevencombs/GrokGauge"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on cask: "grok-build"
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

    The Grok CLI (the grok-build cask) was installed with GrokGauge. GrokGauge
    reads the CLI's login, so sign in once if you haven't already:
      grok login
    (If "grok" isn't found, open a new Terminal window.) A copy from xAI's own
    installer in ~/.grok can stay; both share the same login.

    Grok Bot usage appears automatically if the Grok Bot app is installed.
  EOS
end
