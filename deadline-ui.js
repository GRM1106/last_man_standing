export function countdownText(deadline, now = new Date()) {
  const remaining = new Date(deadline) - now;
  if (remaining <= 0) return "Picks closed";
  const days = Math.floor(remaining / 86400000);
  const hours = Math.floor((remaining % 86400000) / 3600000);
  const minutes = Math.floor((remaining % 3600000) / 60000);
  const seconds = Math.floor((remaining % 60000) / 1000);
  return `${days ? `${days}d ` : ""}${String(hours).padStart(2, "0")}h ${String(minutes).padStart(2, "0")}m ${String(seconds).padStart(2, "0")}s`;
}

export function updatePickDeadlineStates(root = document, now = new Date()) {
  root.querySelectorAll("[data-deadline]").forEach((element) => {
    const passed = new Date(element.dataset.deadline) <= now;
    element.textContent = countdownText(element.dataset.deadline, now);
    const deadline = element.closest(".selection-deadline");
    deadline?.classList.toggle("passed", passed);
    if (!passed) return;
    const label = deadline?.querySelector("strong");
    if (label) label.textContent = "Picks closed";
    element.closest(".selection-panel")?.querySelectorAll(".pick-team").forEach((button) => {
      button.disabled = true;
    });
  });
}
