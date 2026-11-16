# T3 Widget

A small always-on-top **macOS** panel for T3 Code, pinned to the top-left corner of the main screen, that shows:

- **Active T3 Code threads**: title, project, elapsed time, what the agent is doing right now
  (shell command, tool, thinking, writing), and the last few lines of its output.
- **Threads that ended in the last 24 hours**, most recently interacted with first.
- Threads from **every linked environment** (your other machines), tagged `@ <machine>`.
- An **activity graphic** in the header that animates while any thread is working: a robot
  typing at a computer, or a cat banging on a keyboard.

It hides itself whenever the T3 Code server isn't running.

## How it works

- **This Mac**: it polls T3's local state DB (`~/.t3/userdata/statev2.sqlite`) every 2 s,
  **read-only**. It skips subagent, archived and deleted threads. These are internal T3 tables,
  so a T3 update could rename them. If that happens, the widget shows the SQLite error inline.
- **Linked environments**: every 3 s it asks the local T3 server's MCP endpoint (`/mcp`), which
  relays to each linked machine (`t3_environment_links`, `t3_thread_list`, `t3_thread_read`).
  It signs in as a **read-only** MCP client: on first run it issues its own session with
  `t3 auth session issue --subject mcp-client --scope orchestration:read --ttl 30d` and keeps
  it in `~/Library/Application Support/T3Widget/mcp-session.json` (mode 0600). It renews the
  session before it expires and revokes the old one. Unreachable machines show as a note.

It checks liveness with the PID in `~/.t3/userdata/server-runtime.json`.

## Build / run

```sh
./build.sh             # builds build/T3 Widget.app
open "build/T3 Widget.app"
./build.sh --install   # copy to ~/Applications and start at login (LaunchAgent)
```

Needs only the Xcode Command Line Tools (`swiftc`). Requires macOS 13 or later.

## Controls

The widget never takes keyboard focus, so everything is done with the mouse or trackpad.

### Mouse and trackpad

| Action | What it does |
| --- | --- |
| Drag anywhere on the widget | Move it. It remembers where you leave it, across restarts. |
| Click the header | Collapse to just the header, or expand again. |
| Click a thread | Bring T3 Code to the front. |
| Click the activity graphic | Switch between the robot and the cat. |
| Pinch in or out | Zoom between 100% and 300%. |
| ⌘ + scroll | Zoom between 100% and 300%. |
| Right-click | Open the menu below. |

### Right-click menu

| Item | What it does |
| --- | --- |
| **Stay on Top** | On (default): floats above all windows, on every Space and over full-screen apps. Off: behaves like a normal window that others can cover; click it to bring it forward. |
| **Reset Position** | Move it back to the top-left corner of the main screen. |
| **Zoom** ▸ Zoom In / Zoom Out | Step the size up or down by 25%. |
| **Zoom** ▸ 100% … 300% | Jump to a preset size (100, 125, 150, 175, 200, 250 or 300%). The current one is checked. |
| **Activity Graphic** ▸ Typing Robot / Keyboard Cat | Choose the header graphic. |
| **Open T3 Code** | Bring T3 Code to the front. |
| **Quit T3 Widget** | Quit. If it was installed with `--install`, it starts again at your next login. |

Zoom scales the text, spacing and width together. Zoom, graphic, Stay on Top and position are
saved between launches. To reset them all: `defaults delete local.lab.t3widget`, then restart
the widget.

### Reading the widget

- **Header**: the activity graphic, then how many threads are active. The graphic animates while
  any thread is working (running, starting or preparing) and rests when nothing is.
- **Status dots**: green = working, yellow = queued or waiting for your input, gray = completed,
  red = failed, orange = interrupted, cancelled or rolled back.
- **Active threads**: title and elapsed time, then what the agent is doing right now with the
  project (and `@ machine` for threads on another machine), then the last lines of its output.
- **Ended · last 24h**: threads that finished in the past day, most recent first, with how long
  ago you last interacted with them.
- **Orange notes** under the header: a linked machine that couldn't be reached, and why.

## Debugging

`T3WIDGET_DEBUG=1 "build/T3 Widget.app/Contents/MacOS/T3Widget"` prints each snapshot to stderr.

## Uninstall

Run `launchctl bootout gui/$(id -u)/local.lab.t3widget`, then delete
`~/Library/LaunchAgents/local.lab.t3widget.plist` and `~/Applications/T3 Widget.app`. Revoke its
session with `t3 auth session list` / `t3 auth session revoke <id>` (label "T3 Widget") and
delete `~/Library/Application Support/T3Widget`.

## Caveats

This is an unofficial tool, not affiliated with T3 Code. It reads T3's internal state database
and calls its MCP endpoint, neither of which is a stable public API, so a T3 update can break it.

## License

MIT, see [LICENSE](LICENSE).
