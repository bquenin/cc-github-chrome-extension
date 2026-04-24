#!/bin/bash
# Legacy handler for agent-pr-review://, github-pr-review://, and claude-review:// URL schemes
# Receives a URL like: agent-pr-review://github.com/owner/repo/pull/123?cli=claude
# Opens Terminal and runs claude to review the PR

URL="$1"

# Strip the scheme to get the GitHub path
GH_PATH="${URL#agent-pr-review://}"
if [[ "$GH_PATH" == "$URL" ]]; then
  GH_PATH="${URL#github-pr-review://}"
fi
if [[ "$GH_PATH" == "$URL" ]]; then
  GH_PATH="${URL#claude-review://}"
fi

# Drop any query string
GH_PATH="${GH_PATH%%\?*}"
PR_URL="https://${GH_PATH}"

# Validate it looks like a GitHub PR URL
if [[ ! "$GH_PATH" =~ ^github(\.[a-zA-Z0-9.-]+)?\.[a-zA-Z]+/[^/]+/[^/]+/pull/[0-9]+ ]]; then
  osascript -e "display dialog \"Invalid PR URL: ${PR_URL}\" with title \"Agent PR Review\" buttons {\"OK\"} default button 1 with icon stop"
  exit 1
fi

# Open Terminal and run claude
osascript <<EOF
tell application "Terminal"
  activate
  do script "claude -p 'Please review this PR: ${PR_URL}. Use the gh CLI to get PR details, diff, and file contents. Provide a thorough code review covering: correctness, security, performance, and style. Post your review as a PR review comment using gh CLI.'"
end tell
EOF
