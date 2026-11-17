#!/bin/bash
# Build, bundle, sign and (un)install Headroom.app and the `headroom` CLI.
#
#   ./build.sh                 build build/Headroom.app (ad-hoc signed)
#   ./build.sh install [-y]    build, copy to /Applications, link the CLI, launch
#   ./build.sh install-agent   start at login via a LaunchAgent instead of SMAppService
#   ./build.sh uninstall       remove the app, login item / LaunchAgent and CLI link
#
# -y skips the confirmation before writing the CLI link outside the project.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="Headroom"
BUNDLE_ID="com.amirali.headroom"
BUILD_APP="$ROOT/build/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
SUPPORT="$HOME/Library/Application Support/Headroom"
YES=0

step() { printf '\n==> %s\n' "$*"; }

confirm() {
    [[ $YES == 1 ]] && return 0
    read -r -p "$1 [y/N] " answer
    [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

cli_link_dir() {
    if [[ -d /opt/homebrew/bin ]]; then echo /opt/homebrew/bin
    else echo /usr/local/bin; fi
}

build() {
    step "Compiling (release, arm64)"
    swift build -c release --arch arm64
    local bin
    bin="$(swift build -c release --arch arm64 --show-bin-path)"

    step "Assembling $BUILD_APP"
    rm -rf "$BUILD_APP"
    mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Helpers" "$BUILD_APP/Contents/Resources"
    cp "$bin/HeadroomApp" "$BUILD_APP/Contents/MacOS/$APP_NAME"
    # Not in Contents/MacOS: "headroom" would collide with "Headroom" on a case-insensitive disk.
    cp "$bin/headroom" "$BUILD_APP/Contents/Helpers/headroom"
    cp "$ROOT/Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"
    printf 'APPL????' > "$BUILD_APP/Contents/PkgInfo"

    step "Signing (ad-hoc)"
    codesign --force --sign - --identifier "$BUNDLE_ID.cli" "$BUILD_APP/Contents/Helpers/headroom"
    codesign --force --sign - "$BUILD_APP"
    codesign --verify --deep --strict "$BUILD_APP"
    echo "Built $BUILD_APP"
}

quit_running() {
    if pgrep -xq "$APP_NAME"; then
        step "Quitting running $APP_NAME"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq "$APP_NAME" || break; sleep 0.5; done
        pkill -x "$APP_NAME" 2>/dev/null || true
    fi
}

link_cli() {
    local dir link
    dir="$(cli_link_dir)"
    link="$dir/headroom"
    if [[ -L $link && "$(readlink "$link")" == "$INSTALL_APP/Contents/Helpers/headroom" ]]; then
        echo "CLI already linked at $link"
        return
    fi
    if [[ -e $link && ! -L $link ]]; then
        echo "Not linking the CLI: $link exists and isn't a symlink. Remove it and re-run."
        return
    fi
    if confirm "Link the CLI at $link (outside this project)?"; then
        step "Linking CLI at $link"
        ln -sf "$INSTALL_APP/Contents/Helpers/headroom" "$link"
    else
        echo "Skipped. Run it as $INSTALL_APP/Contents/Helpers/headroom"
    fi
}

install() {
    build
    quit_running
    step "Installing to $INSTALL_APP"
    rm -rf "$INSTALL_APP"
    cp -R "$BUILD_APP" "$INSTALL_APP"
    link_cli
    step "Launching"
    open "$INSTALL_APP"
    echo "Installed. Look for Headroom in the menu bar."
}

install_agent() {
    [[ -d $INSTALL_APP ]] || { echo "Install first: ./build.sh install"; exit 1; }
    step "Unregistering the SMAppService login item (avoids starting twice)"
    "$INSTALL_APP/Contents/MacOS/$APP_NAME" --unregister || true
    step "Writing $AGENT"
    mkdir -p "$(dirname "$AGENT")"
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST
    step "Loading LaunchAgent"
    quit_running
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    echo "Headroom will start at login via $AGENT"
}

uninstall() {
    quit_running
    if [[ -d $INSTALL_APP ]]; then
        step "Unregistering login item"
        "$INSTALL_APP/Contents/MacOS/$APP_NAME" --unregister || true
    fi
    if [[ -f $AGENT ]]; then
        step "Removing LaunchAgent"
        launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
        rm -f "$AGENT"
    fi
    local link
    link="$(cli_link_dir)/headroom"
    if [[ -L $link && "$(readlink "$link")" == "$INSTALL_APP/Contents/Helpers/headroom" ]]; then
        step "Removing CLI link $link"
        rm -f "$link"
    fi
    if [[ -d $INSTALL_APP ]]; then
        step "Removing $INSTALL_APP"
        rm -rf "$INSTALL_APP"
    fi
    echo
    echo "Uninstalled. Config and session were left in: $SUPPORT"
}

cmd="${1:-build}"
shift || true
for arg in "$@"; do [[ $arg == -y || $arg == --yes ]] && YES=1; done
case "$cmd" in
    build) build ;;
    install) install ;;
    install-agent) install_agent ;;
    uninstall) uninstall ;;
    *) echo "usage: $0 [build|install [-y]|install-agent|uninstall]"; exit 1 ;;
esac
