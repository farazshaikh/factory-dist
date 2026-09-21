document.getElementById("copy-command").addEventListener("click", async () => {
  const status = document.getElementById("copy-status");
  try {
    await navigator.clipboard.writeText(document.getElementById("install-command").textContent);
    status.textContent = "Install command copied.";
  } catch {
    status.textContent = "Clipboard unavailable. Select and copy the command above.";
  }
});