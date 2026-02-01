window.addEventListener("load", () => {
  const from = "Python_Interface_Documentation";
  const to = "Python Interface Documentation";

  // Page <title>
  document.title = document.title.replace(from, to);

  // Page title header
  const topContent = document.getElementById("top-content");
  const spans = topContent?.querySelectorAll("span");
  spans?.forEach((span) => {
    if (span.textContent.includes(from)) {
      span.textContent = span.textContent.replace(from, to);
    }
  });

  // All links
  const links = document.querySelectorAll("a");
  links?.forEach((link) => {
    if (link.textContent.includes(from)) {
      link.textContent = link.textContent.replace(from, to);
    }
  });

  // Drop source code links
  if (document.title.includes(to)) {
    const view_source = document.querySelectorAll(".icon-action");
    view_source?.forEach((view_source) => {
      const expected_title = "View Source";
      if (
        view_source.getAttribute("title") == expected_title ||
        view_source.getAttribute("aria-label") == expected_title
      ) {
        view_source.remove();
      }
    });
  }

  // Autocomplete description (module)
  const autocomplete = document.getElementsByClassName("autocomplete")[0];
  const observer = new MutationObserver(() => {
    const descriptions = autocomplete?.querySelectorAll(".description");
    descriptions?.forEach((description) => {
      if (description.textContent.includes(from)) {
        description.textContent = description.textContent.replace(from, to);
      }
    });
  });
  observer.observe(autocomplete, { childList: true, subtree: true });
});
