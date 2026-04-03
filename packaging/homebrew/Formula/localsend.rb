# typed: true
# frozen_string_literal: true

class Localsend < Formula
  desc "Send and receive files over LAN via CLI"
  homepage "https://localsend.org"
  version "1.0.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/tommyme/homebrew-tap/releases/download/localsend-1.0.0/localsend_macos_arm64"
      sha256 "TODO: Add SHA256 after first release"
    end
    on_intel do
      url "https://github.com/tommyme/homebrew-tap/releases/download/localsend-1.0.0/localsend_macos_x86_64"
      sha256 "TODO: Add SHA256 after first release"
    end
  end

  def install
    bin.install "localsend"
  end

  def plist
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>org.localsend.localsend</string>
        <key>ProgramArguments</key>
        <array>
          <string>#{opt_bin}/localsend</string>
          <string>--receive</string>
          <string>--auto</string>
          <string>--output</string>
          <string>#{ENV["HOME"]}/Downloads</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/var/log/localsend.log</string>
        <key>StandardErrorPath</key>
        <string>/var/log/localsend.log</string>
      </dict>
      </plist>
    PLIST
  end

  test do
    system "#{bin}/localsend", "--version"
  end
end
