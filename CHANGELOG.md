# Changelog

## 1.0.0 - 2026-08-31

- First release: manage Docker containers from the Omarchy bar. The icon
  turns urgent when a container needs attention; the popup lists every
  container with its state, and always shows live CPU/RAM per container
  plus a total normalized against the whole machine.
- Start, stop, restart, pause/resume and kill straight from the row; stop and
  restart never need the row expanded first.
- Removing a container is behind a confirmation dialog that starts on
  Cancel, and is only offered where docker will actually allow it — nothing
  running, paused, or restarting can be removed. Plain `docker rm`, never
  `-f` or `-v`, so the image and every volume survive.
- Click a row to expand it: image, published ports, and the actions that
  don't earn a permanent button — view logs, open a shell, pause/kill, and
  one "open" button per published port while the container is running.
  Logs and the shell open in a terminal window rather than inside the popup.
- CPU/RAM is sampled on its own slower timer, separate from the container
  list, since `docker stats` waits about two seconds for a sample no matter
  how many containers exist — and only while the popup is actually open.
- Follows docker's own state machine rather than a running/stopped guess: a
  paused container is never offered Start (which cannot resume it), and one
  stuck in a restart loop counts as active rather than being read as
  "stopped".
- No `Service.qml` and nothing persisted to disk — every read is a live
  docker call, capped in size before it is parsed either way.
- Never elevates privileges: every docker call is the plain `docker` CLI run
  as the user. If the daemon is unreachable or the socket refuses the user,
  the popup says which in as many words rather than failing silently.
- Tests run in GitHub Actions: the parsing/state-rule/formatting logic under
  Node, a syntax and executable-bit check on the helper script, and the
  helper itself against a real docker daemon — list, stats, restart, stop,
  and both a refused and an accepted remove.
