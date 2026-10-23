# Menu bar app design

## Purpose

A personal macOS app that shows current Claude Code and Codex subscription usage directly in the menu bar. It uses the logins already present on this Mac.

## Always-visible display

- Two separate menu bar items: one for Claude Code and one for Codex.
- Each item starts with the provider's logo and has two horizontal gauge rows. The upper row shows the shorter usage window, normally five hours; the lower row shows the longer window, normally one week. Each row includes its actual window label and percent used.
- Use the terminal script's color thresholds: green `#a6e3a1` through 50%, yellow `#f9e2af` from 51% through 75%, and pink `#f38ba8` above 75%. Keep labels and gauges compact when menu bar space is tight.
- Label windows with the duration returned by the provider, including when Codex changes a window length. Do not present an omitted window as 0%: show an empty gauge marked unavailable.
- Before the first successful fetch, reserve the normal item space with empty gauges and a loading or error marker.
- After a failed refresh, retain the last successful reading and mark it stale. After wake, keep the old display until the next scheduled refresh.

## On click

Each item opens a detail panel for that provider. Show both percentages, reset times, the last successful update time, the current error if any, and a Refresh control. Show Claude extra-usage credits in its detail panel when present. Include re-login instructions for expired Codex credentials and a setting to enable or disable launch at login.

## Fetching and state

- Fetch directly in Swift using the data sources and parsing rules established by `ai-plan-usage.sh`. Do not require the shell script, `jq`, or `curl` at runtime.
- Refresh on launch and every ten minutes while running. A manual refresh is available in each detail panel.
- Cache Claude access tokens only in memory until shortly before expiry; keep fetching current subscription usage from the API every ten minutes. Background credential reads must not show Keychain prompts or launch Claude CLI. Offer an explicit Reconnect Claude action to allow Keychain access and renew an expired login through the CLI; the small renewal prompt may consume plan allowance. If the Codex login expires, show instructions to renew it rather than starting Codex in the background.
- Keep the latest successful reading in memory. Version one has no history or trend charts and sends no notifications.
- Treat the current usage endpoints as changeable. If a request or response fails, show the failure in the detail panel and preserve a stale reading when one exists.

## Build notes

Use a native macOS app with custom menu bar visuals and provider-specific detail panels. Zed can be the day-to-day editor; install Xcode for the macOS build tools. Validate early that the two-row gauges, percentage labels, and logos render legibly in the menu bar, and that a signed app can read the existing credentials.
