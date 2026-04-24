# Agent PR Review Launcher — Chrome Extension

A Chrome extension that adds a review launcher to GitHub PR pages. You can choose **Cursor CLI (`agent`)** or **Claude Code**, and clicking the primary action opens an iTerm2 tab, `cd`s into your local clone of the repo, and launches the selected CLI in interactive mode to review the PR.

## How it works

1. The Chrome extension injects a review launcher into GitHub PR pages
2. You choose Cursor or Claude from the dropdown, then click the primary action
3. Clicking the action triggers an `agent-pr-review://` custom URL scheme
4. A lightweight macOS URL handler finds the repo locally, opens an iTerm2 tab, and launches the selected CLI with a review prompt
5. Reopening the same PR resumes the previous review session for that CLI

No background processes, no servers — just a URL scheme handler.

## Prerequisites

- macOS
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed and authenticated
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- [iTerm2](https://iterm2.com/)
- Google Chrome

## Installation

### 1. Install the URL scheme handler

```bash
cd handler
./install.sh
```

This compiles a small Swift app, places it in `~/Applications/AgentPRReview.app`, and registers the `agent-pr-review://` URL scheme. It also keeps `github-pr-review://` and `claude-review://` registered as compatibility aliases.

### 2. Load the Chrome extension

1. Open Chrome and navigate to `chrome://extensions`
2. Enable **Developer mode** (toggle in top-right)
3. Click **Load unpacked**
4. Select the `extension/` directory

## Usage

1. Navigate to any GitHub pull request
2. Use the amber review launcher in the PR header
3. The primary action defaults to **Cursor** for now; use the dropdown chevron to switch to **Claude**
4. An iTerm2 tab opens in your local repo with the selected CLI reviewing the PR
5. Click the primary action again on the same PR to **resume** the previous review session

## Customization

### GitHub Enterprise

By default, the extension only runs on `github.com`. To add a GitHub Enterprise instance, edit `extension/manifest.json`:

```json
{
  "host_permissions": ["https://github.com/*", "https://github.example.com/*"],
  "content_scripts": [
    {
      "matches": ["https://github.com/*/pull/*", "https://github.example.com/*/pull/*"],
      ...
    }
  ]
}
```

Replace `github.example.com` with your GHE domain. Reload the extension after editing.

### Local repo search path

The handler searches for repos under `~/code` (up to 4 levels deep). To change this, edit `handler/ClaudeReviewHandler.swift` and update this line:

```swift
let codeDir = "\(HOME_DIR)/code"
```

Then reinstall with `./install.sh`.

### Terminal app

The handler uses iTerm2 by default. To use a different terminal, edit the AppleScript block in `handler/ClaudeReviewHandler.swift`. For example, to use Terminal.app:

```swift
let script = """
tell application "Terminal"
    activate
    do script "\(asCmd)"
end tell
"""
```

Then reinstall with `./install.sh`.

### Review prompt

The initial prompt sent to Cursor or Claude can be customized in `handler/ClaudeReviewHandler.swift`:

```swift
let prompt = "Please review this PR: \(prURL). Switch to the local PR branch to help. Consider existing PR comments and review feedback as context for your review."
```

Then reinstall with `./install.sh`.

## How session resume works

Each PR gets a stable review key derived from `owner/repo/pull/number`.

- Claude uses a deterministic UUID. On first click, Claude starts with `--session-id <uuid>`. On subsequent clicks, it detects the existing session and uses `--resume <uuid>`.
- Cursor stores a local PR-to-chat mapping and reuses that chat ID on subsequent clicks for the same PR.

The URL is normalized before generating the session ID, so clicking from `/pull/123`, `/pull/123/files`, or `/pull/123/commits` all map to the same session.

To reset a review session:

```bash
# Find and delete a specific Claude session
find ~/.claude/projects -name '<session-uuid>.jsonl' -delete

# Reset all saved Cursor PR mappings
rm ~/Library/Application\ Support/AgentPRReview/agent-session-map.json
```

## Uninstall

```bash
# Remove the URL handler
rm -rf ~/Applications/AgentPRReview.app ~/Applications/GitHubPRReview.app ~/Applications/ClaudeReview.app

# Remove the Chrome extension from chrome://extensions
```

## Troubleshooting

Check the log file for errors:

```bash
cat ~/Library/Application\ Support/AgentPRReview/agent-pr-review.log
```
