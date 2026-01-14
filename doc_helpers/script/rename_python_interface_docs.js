window.addEventListener("load", () => {
  from = "Python_Interface_Docs";
  to = "Python Interface Docs";

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
