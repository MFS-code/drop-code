# DropCode

A warm, drop-down AI coding terminal for macOS.

![DropCode](docs/dropcode.png)

DropCode embeds [`libghostty`](https://ghostty.org) and starts its terminal
session when the app launches, so your agent is ready before the panel appears.
Ghostty.app is not required.

- Tap `Control+Command` to toggle the panel.
- Hold `Control+Command` to show it until you release the keys.
- Launch OpenCode, Codex, Claude, Cursor Agent, or any custom shell command.
- Adjust panel height, centered width, and window opacity from settings.
- Forward terminal completion requests to macOS desktop notifications.
- Keep the colors and theme configured by the launched CLI.

For OpenCode completion alerts, enable **Desktop notifications** in DropCode
and enable **Attention** in OpenCode settings. Other launchers work when they
emit standard OSC desktop-notification sequences.

## Download

Download a build from [GitHub Releases](https://github.com/R44VC0RP/drop-code/releases), unzip it, and move `DropCode.app` to Applications.

## Build

Requires macOS 13 or newer, Xcode, and your chosen agent CLI on `PATH`.

```sh
./scripts/build-app.sh
open .build/DropCode.app
```

To build, copy the app to `/Applications`, and relaunch it in one step:

```sh
./scripts/install-app.sh
```

Builds are ad-hoc signed by default, so macOS treats every rebuild as a new
app and resets its permissions (Accessibility, notifications). The
`Control+Command` gesture keeps working without Accessibility access. To keep
permissions across builds, use an Apple signing identity:

```sh
SIGNING_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" ./scripts/build-app.sh
```
