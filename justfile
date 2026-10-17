# Couch Remote: menu bar app, tvctl and TVKit.

app := "build/Couch Remote.app"
sources := "Sources Tests Package.swift"

default:
    @just --list --unsorted

# Debug build of everything.
[group('build')]
build:
    swift build

# Release-build Couch Remote.app and tvctl into build/.
[group('build')]
app:
    scripts/build-app.sh

# Remove SwiftPM and app build output.
[group('build')]
clean:
    rm -rf .build build

# Build and launch the app; pass --window, --settings, --light or --dark.
[group('run')]
run *ARGS: app
    -pkill -f "MacOS/CouchRemote"
    "{{app}}/Contents/MacOS/CouchRemote" {{ARGS}} &

# Run tvctl, e.g. `just tv info`.
[group('run')]
tv *ARGS:
    swift run -q tvctl {{ARGS}}

[group('qa')]
test:
    swift test

# Check formatting and lint; fails on any warning.
[group('qa')]
lint: _swiftlint
    swift format lint --strict --recursive {{sources}}
    swiftlint lint --strict --quiet

# Format sources and apply SwiftLint's safe fixes.
[group('qa')]
fmt: _swiftlint
    swift format format --in-place --recursive {{sources}}
    swiftlint lint --fix --quiet

# Everything CI runs, plus the release build.
[group('qa')]
check: lint test app

# Install the app to ~/Applications and tvctl to dest.
[group('install')]
install dest="~/.local/bin": app
    rm -rf ~/Applications/"Couch Remote.app"
    mkdir -p ~/Applications {{dest}}
    cp -R "{{app}}" ~/Applications/
    install -m 0755 build/tvctl {{dest}}/tvctl
    @echo "Installed ~/Applications/Couch Remote.app and {{dest}}/tvctl"

# Remove the installed app and tvctl.
[group('install')]
uninstall dest="~/.local/bin":
    rm -rf ~/Applications/"Couch Remote.app"
    rm -f {{dest}}/tvctl
    @echo "Removed ~/Applications/Couch Remote.app and {{dest}}/tvctl"

# Download App Store icons for catalog apps that have none yet.
[group('assets')]
icons:
    scripts/fetch-icons.sh

# Retake the light and dark README screenshots (needs the TV on).
[group('assets')]
screenshots: app
    #!/usr/bin/env bash
    set -euo pipefail
    log=$(mktemp)
    for mode in light dark; do
        pkill -f "MacOS/CouchRemote" || true
        sleep 1
        "{{app}}/Contents/MacOS/CouchRemote" --window --$mode > "$log" 2>&1 &
        sleep 8
        id=$(grep -o 'remote window [0-9]*' "$log" | awk '{print $3}')
        screencapture -l "$id" docs/assets/screenshot-$mode.png
    done
    pkill -f "MacOS/CouchRemote" || true
    rm -f "$log"

[private]
_swiftlint:
    @command -v swiftlint >/dev/null 2>&1 || { echo "couch-remote: swiftlint not found — brew install swiftlint" >&2; exit 1; }
