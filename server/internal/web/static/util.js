export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[ch]);
}

export async function api(method, path, body) {
  const response = await fetch(path, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(data.error || "Запрос не выполнен");
    error.status = response.status;
    error.payload = data;
    throw error;
  }
  return data;
}

export const get = (path) => api("GET", path);
export const post = (path, body) => api("POST", path, body ?? {});

export function ago(value) {
  if (!value) return "";
  const then = new Date(value).getTime();
  if (Number.isNaN(then)) return "";
  const seconds = Math.max(0, (Date.now() - then) / 1000);
  if (seconds < 90) return "только что";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} мин назад`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} ч назад`;
  if (seconds < 172800) return "вчера";
  if (seconds < 86400 * 14) return `${Math.floor(seconds / 86400)} дн. назад`;
  if (seconds < 86400 * 60) return `${Math.floor(seconds / 86400 / 7)} нед. назад`;
  return `${Math.floor(seconds / 86400 / 30)} мес. назад`;
}

export function greeting(name) {
  const hour = new Date().getHours();
  const hello = hour < 12 ? "Доброе утро" : hour < 18 ? "Добрый день" : "Добрый вечер";
  return `${hello}, ${name}`;
}

export function dayLabels() {
  const names = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"];
  const labels = [];
  for (let i = 6; i >= 0; i -= 1) {
    const date = new Date();
    date.setDate(date.getDate() - i);
    labels.push(i === 0 ? "сегодня" : names[date.getDay()]);
  }
  return labels;
}

export function short(sha) {
  return String(sha || "").slice(0, 7);
}

export function copy(text) {
  if (navigator.clipboard) return navigator.clipboard.writeText(text);
  return Promise.resolve();
}

export function icon(name) {
  const paths = {
    home: '<path d="M4 11.5 12 4l8 7.5V20a1 1 0 0 1-1 1h-5v-6H10v6H5a1 1 0 0 1-1-1v-8.5Z"/>',
    repo: '<path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v11a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 17.5v-11Z"/><path d="M8 8h8M8 12h8M8 16h5"/>',
    pr: '<circle cx="7" cy="7" r="2.2"/><circle cx="7" cy="17" r="2.2"/><circle cx="17" cy="12" r="2.2"/><path d="M7 9.2v5.6M9.1 7h4.2a3 3 0 0 1 3 3v0"/>',
    issue: '<circle cx="12" cy="12" r="8"/><path d="M12 8v4M12 16h.01"/>',
    build: '<path d="M5 16.5 9 8l3 5 2-3 5 6.5"/><path d="M4 19h16"/>',
    release: '<path d="M12 3v10"/><path d="m8 9 4 4 4-4"/><path d="M5 15v4h14v-4"/>',
    search: '<circle cx="11" cy="11" r="6"/><path d="m16 16 4 4"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M12 3.5v2.2M12 18.3v2.2M4.8 6.2l1.6 1.6M17.6 16.2l1.6 1.6M3.5 12h2.2M18.3 12h2.2M4.8 17.8l1.6-1.6M17.6 7.8l1.6-1.6"/>',
    folder: '<path d="M3.5 8.5V7A1.5 1.5 0 0 1 5 5.5h4l2 2H19A1.5 1.5 0 0 1 20.5 9v8A1.5 1.5 0 0 1 19 18.5H5A1.5 1.5 0 0 1 3.5 17V8.5Z"/>',
    file: '<path d="M7 3.5h6l4 4V20a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4.5a1 1 0 0 1 1-1Z"/><path d="M13 3.5V8h4.5"/>',
  };
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${paths[name] || ""}</svg>`;
}

export function statusDot(status) {
  const map = { failed: "bad", failure: "bad", conflict: "bad", offline: "warn", ahead: "warn", local: "idle", synced: "ok", success: "ok" };
  return `<i class="dot ${map[status] || "idle"}"></i>`;
}

export function queueDots(jobs) {
  return (jobs || []).map((_, index) => `<i style="animation-delay:${index * 200}ms"></i>`).join("");
}

let toastTimer = 0;
export function toast(text, tone = "", hold = 2800) {
  document.querySelector(".toast")?.remove();
  const node = document.createElement("div");
  node.className = `toast ${tone}`.trim();
  node.textContent = text;
  document.body.appendChild(node);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    node.classList.add("out");
    setTimeout(() => node.remove(), 220);
  }, hold);
}

export function themeName() {
  return document.documentElement.dataset.theme === "light" ? "light" : "dark";
}

export function setTheme(theme) {
  const next = theme === "light" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem("el-theme", next); } catch { /* private mode */ }
}

export function modeLabel(mode) {
  if (mode === "push") return "push при слиянии";
  if (mode === "both") return "двусторонний";
  return "только локально";
}
