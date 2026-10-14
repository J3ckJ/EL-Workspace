import { esc, get, icon, queueDots, setTheme, statusDot, themeName, toast } from "./util.js";
import { render } from "./views.js";

const app = document.querySelector("#app");
let shellData = null;

function path() {
  const raw = (location.hash || "#/").replace(/^#/, "");
  const [route, query] = raw.split("?");
  return { parts: route.split("/").filter(Boolean), query: new URLSearchParams(query || "") };
}

function shell(active) {
  const counts = shellData?.counts || {};
  const repos = shellData?.repos || [];
  const server = shellData?.server || {};
  const backup = shellData?.backup || {};
  const pins = repos.filter((repo) => repo.pinned).slice(0, 6);
  return `
    <aside class="sidebar">
      <div class="brand"><span class="mark">EL</span> EL Workspace</div>
      ${nav("#/", "home", "Обзор", active === "home")}
      ${nav("#/repos", "repo", "Репозитории", active === "repos", counts.repos)}
      ${nav("#/pulls", "pr", "Pull requests", active === "pulls", counts.pulls)}
      ${nav("#/issues", "issue", "Задачи", active === "issues", counts.issues)}
      ${nav("#/ci", "build", "Сборки", active === "ci", counts.failed ? "•" : "", counts.failed ? "alert" : "")}
      ${nav("#/releases", "release", "Релизы", active === "releases")}
      <button class="nav-item" id="open-search" type="button">${icon("search")} Поиск <kbd>⌘K</kbd></button>
      <div class="group-label">ЗАКРЕПЛЁННЫЕ</div>
      <div class="pins">
        ${pins.map((repo) => `<a class="pin" href="#/r/${esc(repo.owner)}/${esc(repo.name)}">${statusDot(repo.status)} ${esc(repo.name)}</a>`).join("")}
      </div>
      <div class="spacer"></div>
      <div class="theme-switch" role="group" aria-label="Тема">
        <button type="button" data-theme="dark" class="${themeName() === "dark" ? "on" : ""}">Midnight</button>
        <button type="button" data-theme="light" class="${themeName() === "light" ? "on" : ""}">Светлая</button>
      </div>
      ${nav("#/settings", "settings", "Настройки", active === "settings")}
      <a class="server-card" href="#/architecture">
        <strong>${statusDot(shellData?.link?.phase === "conflict" ? "conflict" : shellData?.link?.phase === "offline" ? "offline" : "synced")} Сервер · ${esc(shellData?.host || "localhost")}</strong>
        <span class="tiny"><span>${esc(server.http || "")}</span></span>
        <span class="tiny"><span>Очередь ${shellData?.queue ? shellData.queue : "пуста"}</span><span>Бэкап ${esc(backup.time || backup.label || "")}${backup.ok ? " ✓" : ""}</span></span>
      </a>
    </aside>
    <main class="main" id="view"></main>`;
}

function nav(href, glyph, label, on, count, tone) {
  return `<a class="nav-item${on ? " active" : ""}" href="${href}">${icon(glyph)} ${label} ${count ? `<span class="count ${tone || ""}">${esc(count)}</span>` : ""}</a>`;
}

function forcedState() {
  return new URLSearchParams(location.search).get("state") || "";
}

function remember(data) {
  try {
    sessionStorage.setItem("el-last", JSON.stringify({
      at: new Date().toISOString(),
      host: data?.host || "",
      queue: data?.queue || 0,
    }));
  } catch { /* ignore */ }
}

function lastSeen() {
  try { return JSON.parse(sessionStorage.getItem("el-last") || "null"); } catch { return null; }
}

function serverDown(message) {
  const seen = lastSeen();
  const when = seen?.at ? new Date(seen.at).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" }) : "";
  const queue = Number(seen?.queue || 0);
  app.className = "";
  document.body.className = "";
  app.innerHTML = `<main class="main down">
    <div class="kicker bad">Нет связи</div>
    <h1>Сервер ${esc(seen?.host || "")} недоступен</h1>
    <p class="muted">${esc(message || "Локальный хост не ответил.")}</p>
    ${when ? `<p class="tiny">последняя связь ${esc(when)}</p>` : ""}
    ${queue ? `<p>В очереди ${queue}.</p>` : ""}
    <div class="row" style="justify-content:center;margin-top:16px">
      <button class="btn" id="retry" type="button">Повторить</button>
      <button class="btn ghost" id="diagnose" type="button">Диагностика</button>
    </div>
  </main>`;
  const clearState = (hash) => {
    const url = new URL(location.href);
    url.searchParams.delete("state");
    history.replaceState(null, "", url.pathname + url.search + (hash || location.hash));
    draw();
  };
  document.querySelector("#retry").onclick = () => clearState();
  document.querySelector("#diagnose").onclick = () => clearState("#/architecture");
}

async function draw() {
  const route = path();
  if (forcedState() === "server-down" && (!route.parts.length || route.parts[0] === "panel")) {
    serverDown("Проверка связи с локальным хостом.");
    return;
  }
  if (route.parts[0] === "panel") {
    app.className = "";
    app.innerHTML = `<div id="view"></div>`;
    document.body.className = "panel-mode";
    await render(document.querySelector("#view"), route, openPalette);
    return;
  }
  document.body.className = "";
  app.className = "app";
  try {
    shellData = await get("/api/dashboard");
    remember(shellData);
  } catch (error) {
    serverDown(error.message);
    return;
  }
  const active = activeSection(route.parts);
  app.innerHTML = shell(active);
  document.querySelector("#open-search").addEventListener("click", openPalette);
  document.querySelectorAll(".theme-switch button").forEach((button) => {
    button.addEventListener("click", () => { setTheme(button.dataset.theme); draw(); });
  });
  await render(document.querySelector("#view"), route, openPalette);
  paintSync(shellData.link);
}

let lastPhase = "";
let lastCi = "";
function paintSync(sync) {
  if (!sync) return;
  document.querySelectorAll("[data-sync-scene]").forEach((node) => {
    const state = sync.conflict ? "conflict" : (sync.phase === "offline" || sync.queue) ? "offline" : "synced";
    node.dataset.state = state;
    node.querySelector(".links")?.setAttribute("class", `links ${state === "synced" ? "online" : state}`);
  });
  const key = (sync.jobs || []).map((job) => job.id).join(",");
  document.querySelectorAll(".q").forEach((node) => {
    if (node.dataset.jobs === key) return;
    node.dataset.jobs = key;
    node.innerHTML = queueDots(sync.jobs);
  });
  const count = document.querySelector("[data-sync-counts]");
  if (count) count.textContent = `Совпадает ${sync.synced ?? 0} · входящие ${sync.incoming ?? 0} · очередь ${sync.queue ?? 0}`;
}

async function watchFlow() {
  if (forcedState() === "server-down") return;
  try {
    const sync = await get("/api/sync");
    remember(sync);
    const ciKey = sync.ci ? `${sync.ci.id}:${sync.ci.status}` : "";
    if (lastPhase && sync.phase === "ci" && lastPhase !== "ci") toast("Сборка идёт", "amb", 4000);
    if (lastCi.endsWith(":running") && ciKey.endsWith(":success")) {
      document.querySelectorAll(".dot.ok").forEach((dot) => dot.classList.add("flash"));
      toast("Сборка прошла", "ok", 1500);
    }
    if (lastCi.endsWith(":running") && ciKey.endsWith(":failure")) toast("Сборка упала", "bad", 4000);
    if (lastPhase && sync.phase === "offline" && lastPhase !== "offline") toast(`Зеркало подождёт: в очереди ${sync.queue}`, "amb", 3200);
    if (lastPhase === "offline" && sync.phase === "synced") {
      document.querySelectorAll(".dot.ok").forEach((dot) => dot.classList.add("flash"));
      toast("Зеркало синхронизировано", "ok", 1500);
    }
    if (lastPhase && sync.phase === "conflict" && lastPhase !== "conflict") toast("Зеркало разошлось с домашней копией", "bad", 4000);
    lastPhase = sync.phase;
    lastCi = ciKey;
    paintSync(sync);
  } catch { /* the next navigation shows the unavailable screen */ }
}

function activeSection(parts) {
  if (!parts.length) return "home";
  if (parts[0] === "r") {
    if (parts[3] === "pull" || parts[3] === "pulls") return "pulls";
    if (parts[3] === "issues") return "issues";
    if (parts[3] === "ci") return "ci";
    if (parts[3] === "releases") return "releases";
    return "repos";
  }
  if (parts[0] === "settings" || parts[0] === "architecture") return "settings";
  return parts[0];
}

function openPalette() {
  const wrap = document.createElement("div");
  wrap.className = "palette";
  wrap.innerHTML = `<div class="dialog"><input class="field" id="q" placeholder="Поиск по коду, коммитам, задачам…" autofocus><div id="hits" style="margin-top:10px"></div></div>`;
  document.body.appendChild(wrap);
  const input = wrap.querySelector("#q");
  const hits = wrap.querySelector("#hits");
  let timer = 0;
  input.focus();
  wrap.addEventListener("click", (event) => { if (event.target === wrap) wrap.remove(); });
  input.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      const data = await get("/api/search?q=" + encodeURIComponent(input.value));
      const rows = [];
      for (const repo of data.repos || []) rows.push(`<a class="hit" href="#/r/${esc(repo.owner)}/${esc(repo.name)}"><b>${esc(repo.name)}</b><div class="tiny">${esc(repo.description || "")}</div></a>`);
      for (const item of data.code || []) rows.push(`<a class="hit" href="#/r/${esc(item.owner)}/${esc(item.name)}"><b>${esc(item.path)}</b> <span class="muted">:${esc(item.line)}</span><div class="tiny">${esc(item.text)}</div></a>`);
      for (const item of data.commits || []) rows.push(`<a class="hit" href="#/r/${esc(item.owner)}/${esc(item.name)}/commit/${esc(item.sha)}"><span class="mono">${esc(item.short)}</span> ${esc(item.subject)}</a>`);
      for (const item of data.issues || []) rows.push(`<a class="hit" href="#/issues"><b>#${esc(item.number)}</b> ${esc(item.title)} <span class="tiny">${esc(item.name)}</span></a>`);
      hits.innerHTML = rows.join("") || `<div class="empty">Ничего не найдено</div>`;
      hits.querySelectorAll("a").forEach((link) => link.addEventListener("click", () => wrap.remove()));
    }, 120);
  });
  input.addEventListener("keydown", (event) => { if (event.key === "Escape") wrap.remove(); });
}

window.addEventListener("hashchange", draw);
window.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault();
    openPalette();
  }
});

document.title = "EL Workspace";
draw();
setInterval(watchFlow, 3000);
