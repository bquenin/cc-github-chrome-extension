# Review with Claude Code — Chrome Extension

A Chrome extension that adds a **"Review with Claude Code"** button to GitHub PR pages. Clicking it opens an iTerm2 tab, `cd`s into your local clone of the repo, and launches Claude Code in interactive mode to review the PR.

## How it works

1. The Chrome extension injects a button into GitHub PR pages
2. Clicking the button triggers a `claude-review://` custom URL scheme
3. A lightweight macOS URL handler finds the repo locally, opens an iTerm2 tab, and launches `claude` with a review prompt
4. A deterministic session ID is generated per PR — clicking the button again resumes the previous review session

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

This compiles a small Swift app, places it in `~/Applications/ClaudeReview.app`, and registers the `claude-review://` URL scheme.

### 2. Load the Chrome extension

1. Open Chrome and navigate to `chrome://extensions`
2. Enable **Developer mode** (toggle in top-right)
3. Click **Load unpacked**
4. Select the `extension/` directory

## Usage

1. Navigate to any GitHub pull request
2. Click the **"Review with Claude Code"** button (amber button in the PR header)
3. An iTerm2 tab opens in your local repo with Claude reviewing the PR
4. Click the button again on the same PR to **resume** the previous review session

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

The handler searches for repos under `~/code` (up to 2 levels deep). To change this, edit `handler/ClaudeReviewHandler.swift` and update this line:

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

The initial prompt sent to Claude can be customized in `handler/ClaudeReviewHandler.swift`:

```swift
let prompt = "Please review this PR: \(prURL). Switch to the local PR branch to help. Consider existing PR comments and review feedback as context for your review."
```

Then reinstall with `./install.sh`.

## How session resume works

Each PR gets a deterministic UUID derived from `owner/repo/pull/number`. On first click, Claude starts with `--session-id <uuid>`. On subsequent clicks, it detects the existing session and uses `--resume <uuid>` instead, preserving the full conversation history.

The URL is normalized before generating the session ID, so clicking from `/pull/123`, `/pull/123/files`, or `/pull/123/commits` all map to the same session.

To reset a review session, delete the session file:

```bash
# Find and delete a specific session
find ~/.claude/projects -name '<session-uuid>.jsonl' -delete
```

## Uninstall

```bash
# Remove the URL handler
rm -rf ~/Applications/ClaudeReview.app

# Remove the Chrome extension from chrome://extensions
```

## Troubleshooting

Check the log file for errors:

```bash
cat ~/Applications/claude-review.log
```
