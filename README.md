# Review with Claude Code — Chrome Extension

A Chrome extension that adds a **"Review with Claude Code"** button to GitHub PR pages. Clicking it opens a terminal and runs Claude Code to review the PR.

## How it works

1. The Chrome extension injects a button into GitHub PR pages
2. Clicking the button triggers a `claude-review://` custom URL scheme
3. A lightweight macOS URL handler opens Terminal and runs `claude -p` to review the PR

No background processes, no servers — just a URL scheme handler.

## Prerequisites

- macOS
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed and authenticated
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Google Chrome

## Installation

### 1. Install the URL scheme handler

```bash
cd handler
./install.sh
```

This creates a small `.app` in `~/Applications/` and registers the `claude-review://` URL scheme.

### 2. Load the Chrome extension

1. Open Chrome and navigate to `chrome://extensions`
2. Enable **Developer mode** (toggle in top-right)
3. Click **Load unpacked**
4. Select the `extension/` directory

## Usage

1. Navigate to any GitHub pull request
2. Click the **"Review with Claude Code"** button (amber button in the PR header)
3. A Terminal window opens with Claude reviewing the PR

## Uninstall

```bash
# Remove the URL handler
rm -rf ~/Applications/ClaudeReview.app

# Remove the Chrome extension from chrome://extensions
```
