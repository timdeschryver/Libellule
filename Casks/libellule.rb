# Homebrew cask for Libellule. The release workflow fills in the version and
# checksum when a release is published. Releases are signed ad hoc and not
# notarized, so install without the quarantine flag or macOS refuses to open
# the app:
#   brew tap timdeschryver/libellule https://github.com/timdeschryver/Libellule
#   brew install --cask --no-quarantine libellule
cask "libellule" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/timdeschryver/Libellule/releases/download/v#{version}/Libellule-#{version}.dmg"
  name "Libellule"
  desc "Screenshots, on-screen drawing and copy-text-from-anything, with automatic redaction"
  homepage "https://github.com/timdeschryver/Libellule"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "Libellule.app"

  zap trash: [
    "~/Library/Containers/dev.libellule.Libellule",
    "~/Library/Preferences/dev.libellule.Libellule.plist",
  ]
end
