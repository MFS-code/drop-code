# DropCode

A warm, drop-down AI coding terminal for macOS.

![DropCode](docs/dropcode.png)

DropCode embeds [`libghostty`](https://ghostty.org) and starts its terminal
session when the app launches, so your agent is ready before the panel appears.
Ghostty.app is not required.

- Tap `Control+Command` to toggle the panel.
- Hold `Control+Command` to show it until you release the keys.
- Launch OpenCode, Codex, Claude, Cursor Agent, or any custom shell command.
- Adjust panel height and window opacity from the menu-bar settings.
- Keep the colors and theme configured by the launched CLI.

## Download

Download a build from [GitHub Releases](https://github.com/R44VC0RP/drop-code/releases), unzip it, and move `DropCode.app` to Applications.

## Build

Requires macOS 13 or newer, Xcode, and your chosen agent CLI on `PATH`.

```sh
./scripts/build-app.sh
open .build/DropCode.app
```

Builds are ad-hoc signed by default. To use an Apple signing identity:

```sh
SIGNING_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" ./scripts/build-app.sh
```
