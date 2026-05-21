# claude-usage

Terminal monitor for Claude Code usage limits. Polls the Anthropic OAuth usage endpoint and renders progress bars for 5-hour, 7-day, and (if applicable) extra-credit windows.

## Requirements

- macOS (reads OAuth token from the `Claude Code-credentials` keychain entry)
- `claude` CLI installed and logged in
- `jq`, `curl`, `security`

## Usage

```sh
./claude-usage.sh [--full] [--interval=SECONDS] [--width=N|auto]
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--full` | off | Print raw JSON response instead of bars |
| `--interval=N` | `600` | Seconds between refreshes |
| `--width=N` | `auto` | Bar width in chars; `auto` fits the terminal |

### Example

```sh
./claude-usage.sh --interval=120
```

## Behavior

- Auto-refreshes the OAuth token via `claude -p` when within 60s of expiry.
- Clears the screen each tick when stdout is a TTY.
- Bar color: green ≤50%, yellow ≤75%, red >75%.
- On HTTP 429 or non-200, prints the error and keeps looping.

## Notes

I've found the Claude API will rate-limit you at an interval of 5 mins (300 seconds). 10 mins (600 seconds) seems to be a fine default that I haven't seen rate-limit errors at.
