# macos

Apple Silicon macOS bootstrap. Port of https://github.com/jfspencer/linux.

Prerequisites: Apple Silicon Mac, Xcode 26+ with its developer tools selected
(`sudo xcode-select -s /Applications/Xcode.app`). The script errors out if they
are missing.

Usage:

```sh
./system-setup.sh [OPTIONS]

  --skip-apps               Skip GUI applications (Homebrew casks)
  --skip-desktop-settings   Skip macOS desktop customization (dark mode, dock)
  --skip-gitturtle          Skip building GitTurtle from source
  --dry-run                 Show what would be installed without making changes
  --help                    Show this help message
```

Linux-only pieces (System76/NVIDIA drivers, apt repos, Flatpak, GNOME apps and
settings, Docker Engine, NodeSource) are dropped; Homebrew covers everything
that exists on macOS. Run logs are written to `setup-*.log`.
