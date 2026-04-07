const CLAUDE_ICON_SVG = `<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
  <path d="M12 2L14.09 8.26L20 9.27L15.55 13.97L16.91 20L12 16.9L7.09 20L8.45 13.97L4 9.27L9.91 8.26L12 2Z"/>
</svg>`;

function getPrUrl() {
  const match = window.location.pathname.match(
    /^\/([^/]+)\/([^/]+)\/pull\/(\d+)/
  );
  if (!match) return null;
  // Normalize: always return host/owner/repo/pull/number
  const [, owner, repo, number] = match;
  return `${window.location.host}/${owner}/${repo}/pull/${number}`;
}

function findInsertionPoint() {
  // Strategy: try multiple selectors, broadest to most specific
  const selectors = [
    // GitHub.com and GHE: action buttons container in PR header
    ".gh-header-actions",
    // GHE / older GitHub: the flex row-reverse container with Edit button
    "#partial-discussion-header .flex-md-row-reverse",
    // Another common pattern: header actions area
    ".gh-header-show .flex-md-row-reverse",
    // Fallback: find the Edit button and use its parent
    null, // handled separately below
  ];

  for (const sel of selectors) {
    if (sel) {
      const el = document.querySelector(sel);
      if (el) return el;
    }
  }

  // Last resort: find any element that contains the "Edit" button near the PR title
  const editBtn = Array.from(document.querySelectorAll("button")).find(
    (b) => b.textContent.trim() === "Edit" && b.closest("#partial-discussion-header, .gh-header-show, .js-issue-header-edit-button")
  );
  if (editBtn) return editBtn.parentElement;

  return null;
}

function injectButton() {
  if (document.querySelector(".claude-review-btn")) return;
  if (!getPrUrl()) return;

  const target = findInsertionPoint();
  if (!target) return;

  const btn = document.createElement("button");
  btn.className = "claude-review-btn";
  btn.innerHTML = `${CLAUDE_ICON_SVG} Review with Claude Code`;
  btn.title = "Open a local Claude Code instance to review this PR";

  btn.addEventListener("click", (e) => {
    e.preventDefault();
    const prPath = getPrUrl();
    if (!prPath) return;
    window.location.href = `claude-review://${prPath}`;
  });

  target.prepend(btn);
}

// Run on initial load
injectButton();

// Re-inject on GitHub SPA navigation (turbo/pjax)
const observer = new MutationObserver(() => {
  if (!document.querySelector(".claude-review-btn") && getPrUrl()) {
    injectButton();
  }
});

observer.observe(document.body, { childList: true, subtree: true });

// Also handle popstate for back/forward navigation
window.addEventListener("popstate", () => setTimeout(injectButton, 100));
