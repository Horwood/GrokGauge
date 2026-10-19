# Mirror of github.com/stevencombs/homebrew-tap/blob/main/Casks/grokgauge.rb (keep in sync).
cask "grokgauge" do
  version "0.9.3"
  sha256 "5c7d3515f2a4831c3818ca1b4a9d26d22f1897df5e9a272cf4e94c09ee7c8ad5"

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
