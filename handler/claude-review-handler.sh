#!/bin/bash
# Handler for claude-review:// URL scheme
# Receives a URL like: claude-review://github.com/owner/repo/pull/123
# Opens Terminal and runs claude to review the PR

URL="$1"

# Strip the scheme to get the GitHub path
GH_PATH="${URL#claude-review://}"
PR_URL="https://${GH_PATH}"

# Validate it looks like a GitHub PR URL
if [[ ! "$GH_PATH" =~ ^github(\.[a-zA-Z0-9.-]+)?\.[a-zA-Z]+/[^/]+/[^/]+/pull/[0-9]+ ]]; then
  osascript -e "display dialog \"Invalid PR URL: ${PR_URL}\" with title \"Claude Code Review\" buttons {\"OK\"} default button 1 with icon stop"
  exit 1
fi

# Open Terminal and run claude
osascript <<EOF
tell application "Terminal"
  activate
  do script "claude -p 'Please review this PR: ${PR_URL}. Use the gh CLI to get PR details, diff, and file contents. Provide a thorough code review covering: correctness, security, performance, and style. Post your review as a PR review comment using gh CLI.'"
end tell
EOF
