#!/bin/bash
# Claude Code hook: forwards the hook event (JSON on stdin) to Dynamic Island
# and prints the app's reply on stdout.
#
# Usage:  dynamic-island-hook.sh permission   (PermissionRequest hook — waits for an answer)
#         dynamic-island-hook.sh notify       (Notification hook — fire and forget)
#
# If the app isn't running, times out, or the user picks "Answer in Claude",
# this prints nothing and Claude falls back to its normal prompt.

endpoint="${1:-permission}"
max_time=320
[ "$endpoint" = "notify" ] && max_time=3

# macOS sets __CFBundleIdentifier to the app this session runs in (Claude desktop,
# Terminal, iTerm…). The island skips the popup while that app is in front.
curl --silent --fail --max-time "$max_time" \
  -H 'Content-Type: application/json' \
  -H "X-Claude-Host: ${__CFBundleIdentifier:-}" \
  --data-binary @- \
  "http://127.0.0.1:47823/$endpoint" 2>/dev/null

exit 0
