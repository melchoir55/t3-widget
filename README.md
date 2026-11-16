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

## Using it

- Click the header to collapse or expand.
- Click a thread to bring T3 Code to the front.
- **Zoom** (100–300%): pinch, ⌘-scroll over the widget, or right-click → Zoom.
- Click the activity graphic, or right-click → Activity Graphic, to switch robot / cat.
- Right-click to open T3 Code or quit.
- `T3WIDGET_DEBUG=1 "build/T3 Widget.app/Contents/MacOS/T3Widget"` prints each snapshot to stderr.

To uninstall: `launchctl bootout gui/$(id -u)/local.lab.t3widget`, then delete
`~/Library/LaunchAgents/local.lab.t3widget.plist` and `~/Applications/T3 Widget.app`. Revoke its
session with `t3 auth session list` / `t3 auth session revoke <id>` (label "T3 Widget") and
delete `~/Library/Application Support/T3Widget`.

## Caveats

This is an unofficial tool, not affiliated with T3 Code. It reads T3's internal state database
and calls its MCP endpoint, neither of which is a stable public API, so a T3 update can break it.

## License

MIT, see [LICENSE](LICENSE).
