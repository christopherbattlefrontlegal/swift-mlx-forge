const copyButtons = document.querySelectorAll("[data-copy]");

copyButtons.forEach((button) => {
  const originalText = button.textContent;

  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.textContent = "Copied";
      window.setTimeout(() => {
        button.textContent = originalText;
      }, 1400);
    } catch {
      button.textContent = "Select the command above";
      window.setTimeout(() => {
        button.textContent = originalText;
      }, 1800);
    }
  });
});
