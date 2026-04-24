const REVIEW_ICON_SVG = `<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
  <path d="M12 2L14.09 8.26L20 9.27L15.55 13.97L16.91 20L12 16.9L7.09 20L8.45 13.97L4 9.27L9.91 8.26L12 2Z"/>
</svg>`;

const CHEVRON_ICON_SVG = `<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <path d="M4.22 6.97a.75.75 0 0 1 1.06 0L8 9.69l2.72-2.72a.75.75 0 1 1 1.06 1.06L8.53 11.28a.75.75 0 0 1-1.06 0L4.22 8.03a.75.75 0 0 1 0-1.06Z"/>
</svg>`;

const REVIEW_URL_SCHEME = "agent-pr-review";
const REVIEW_CLI_STORAGE_KEY = "review-cli";
const DEFAULT_REVIEW_CLI = "agent";
const REVIEW_CLIS = {
  agent: {
    menuLabel: "Cursor (agent)",
    buttonLabel: "Review with Cursor",
    title: "Open a local Cursor agent review for this PR",
  },
  claude: {
    menuLabel: "Claude",
    buttonLabel: "Review with Claude Code",
    title: "Open a local Claude Code review for this PR",
  },
};

function getSelectedCli() {
  const savedCli = window.localStorage.getItem(REVIEW_CLI_STORAGE_KEY);
  return REVIEW_CLIS[savedCli] ? savedCli : DEFAULT_REVIEW_CLI;
}

function setSelectedCli(cli) {
  if (REVIEW_CLIS[cli]) {
    window.localStorage.setItem(REVIEW_CLI_STORAGE_KEY, cli);
  }
}

function getLaunchUrl(cli, prPath) {
  const params = new URLSearchParams({ cli });
  return `${REVIEW_URL_SCHEME}://${prPath}?${params.toString()}`;
}

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

function setMenuOpen(launcher, isOpen) {
  launcher.classList.toggle("is-open", isOpen);
  const toggle = launcher.querySelector(".review-launcher-toggle");
  if (toggle) {
    toggle.setAttribute("aria-expanded", String(isOpen));
  }
}

function closeOpenMenus(exceptLauncher = null) {
  document.querySelectorAll(".review-launcher.is-open").forEach((launcher) => {
    if (launcher !== exceptLauncher) {
      setMenuOpen(launcher, false);
    }
  });
}

function createLauncher() {
  const launcher = document.createElement("div");
  launcher.className = "review-launcher";

  const primaryButton = document.createElement("button");
  primaryButton.type = "button";
  primaryButton.className = "review-launcher-primary";

  const toggleButton = document.createElement("button");
  toggleButton.type = "button";
  toggleButton.className = "review-launcher-toggle";
  toggleButton.innerHTML = CHEVRON_ICON_SVG;
  toggleButton.title = "Choose review tool";
  toggleButton.setAttribute("aria-haspopup", "menu");
  toggleButton.setAttribute("aria-expanded", "false");

  const menu = document.createElement("div");
  menu.className = "review-launcher-menu";
  menu.setAttribute("role", "menu");

  const render = () => {
    const selectedCli = getSelectedCli();
    const selectedConfig = REVIEW_CLIS[selectedCli];
    primaryButton.innerHTML = `${REVIEW_ICON_SVG} ${selectedConfig.buttonLabel}`;
    primaryButton.title = selectedConfig.title;

    menu.replaceChildren(
      ...Object.entries(REVIEW_CLIS).map(([cli, config]) => {
        const option = document.createElement("button");
        option.type = "button";
        option.className = "review-launcher-option";
        option.textContent = config.menuLabel;
        option.setAttribute("role", "menuitemradio");
        option.setAttribute("aria-checked", String(cli === selectedCli));

        if (cli === selectedCli) {
          option.classList.add("is-selected");
        }

        option.addEventListener("click", (event) => {
          event.preventDefault();
          setSelectedCli(cli);
          setMenuOpen(launcher, false);
          render();
        });

        return option;
      })
    );
  };

  primaryButton.addEventListener("click", (event) => {
    event.preventDefault();
    const prPath = getPrUrl();
    if (!prPath) return;
    window.location.href = getLaunchUrl(getSelectedCli(), prPath);
  });

  toggleButton.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    const willOpen = !launcher.classList.contains("is-open");
    closeOpenMenus(launcher);
    setMenuOpen(launcher, willOpen);
  });

  launcher.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      setMenuOpen(launcher, false);
      toggleButton.focus();
    }
  });

  launcher.append(primaryButton, toggleButton, menu);
  render();
  return launcher;
}

function injectButton() {
  if (document.querySelector(".review-launcher")) return;
  if (!getPrUrl()) return;

  const target = findInsertionPoint();
  if (!target) return;

  target.prepend(createLauncher());
}

// Run on initial load
injectButton();

document.addEventListener("click", (event) => {
  const target = event.target;
  document.querySelectorAll(".review-launcher.is-open").forEach((launcher) => {
    if (!(target instanceof Element) || !launcher.contains(target)) {
      setMenuOpen(launcher, false);
    }
  });
});

// Re-inject on GitHub SPA navigation (turbo/pjax)
const observer = new MutationObserver(() => {
  if (!document.querySelector(".review-launcher") && getPrUrl()) {
    injectButton();
  }
});

observer.observe(document.body, { childList: true, subtree: true });

// Also handle popstate for back/forward navigation
window.addEventListener("popstate", () => setTimeout(injectButton, 100));
