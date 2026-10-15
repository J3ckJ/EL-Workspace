import { ago, api, copy, dayLabels, esc, get, greeting, icon, modeLabel, post, queueDots, short, statusDot, toast } from "./util.js";

export async function render(root, route, openPalette) {
  const [head, owner, name, section, extra] = route.parts;
  try {
    if (!head) return dashboard(root, openPalette);
    if (head === "repos") return repoList(root);
    if (head === "issues") return board(root);
    if (head === "pulls") return allPulls(root);
    if (head === "ci") return ciList(root);
    if (head === "releases") return releaseList(root);
    if (head === "settings") return settings(root, owner || "mirrors");
    if (head === "architecture") return architecture(root);
    if (head === "panel") return panel(root);
    if (head === "r" && owner && name) {
      if (section === "commit" && extra) return commit(root, owner, name, extra);
      if (section === "pull" && extra) return pull(root, owner, name, extra);
      if (section === "ci" && extra) return ciRun(root, owner, name, extra);
      return repo(root, owner, name, section || "code", route.query);
    }
    root.innerHTML = `<div class="empty">Страница не найдена</div>`;
  } catch (error) {
    root.innerHTML = `<div class="error">${esc(error.message)}</div>`;
  }
}

function pageHead(title, sub, actions) {
  return `<div class="top"><div><h1>${title}</h1>${sub ? `<div class="sub">${sub}</div>` : ""}</div><div class="row">${actions || ""}</div></div>`;
}

async function dashboard(root, openPalette) {
  const data = await get("/api/dashboard");
  const labels = dayLabels();
  const attention = data.attention;
  const head = pageHead(esc(greeting(data.name)), data.repoCount ? `${data.repoCount} репозиториев на ${esc(data.host)} · ${data.mirrored} в зеркале · ${data.localOnly} только локально` : "Локальный хост готов", `
      <button class="search" id="find" type="button"><span>Поиск по коду, коммитам, задачам…</span><kbd>⌘K</kbd></button>
      <button class="btn" id="new-repo" type="button">+ Новый репозиторий</button>`);
  if (!data.repoCount) {
    root.innerHTML = head + `<section class="card empty-state"><h2>Пока ни одного репозитория</h2><p class="muted">Он останется на этой машине. Зеркало можно подключить позже.</p><button class="btn" id="empty-new" type="button">+ Новый репозиторий</button></section>`;
    root.querySelector("#find").addEventListener("click", openPalette);
    root.querySelector("#new-repo").addEventListener("click", () => createRepo());
    root.querySelector("#empty-new").addEventListener("click", () => createRepo());
    return;
  }
  const link = data.link || {};
  root.innerHTML = `
    ${head}
    ${linkBanner(link)}
    <div class="grid-2">
      <section class="card ${attention?.tone === "danger" ? "danger" : ""} attention">
        ${attention ? `<div class="kicker ${attention.tone === "danger" ? "bad" : ""}">${esc(attention.kicker)} · ${esc(ago(attention.at))}</div>
          <h2>${esc(attention.title)}</h2>
          <div class="muted">${esc(brief(attention.detail))}</div>
          <div class="row" style="margin-top:16px">
            <a class="btn" href="${attentionHref(attention)}">${esc(attention.action || "Открыть")}</a>
            ${attention.kind === "ci" ? `<button class="btn ghost" id="rerun" type="button">Перезапустить</button>` : ""}
          </div>` : `<div class="kicker ok">Всё спокойно</div><h2>Нет срочных дел</h2>`}
      </section>
      <section class="card">
        <div class="kicker">Ветки за неделю</div>
        ${weekChart(data.week, labels)}
      </section>
    </div>
    <div class="grid-3" style="margin-top:16px">
      <div>
        <div class="tiny" style="margin-bottom:8px">РЕПОЗИТОРИИ · последняя активность сверху</div>
        <div class="cards">${(data.repos || []).map(repoCard).join("")}</div>
      </div>
      <div>
        <div class="tiny" style="margin-bottom:8px">ЛЕНТА</div>
        <div class="card feed">${(data.activity || []).map(activity).join("") || `<div class="empty">Пока тихо</div>`}</div>
        ${data.clone ? `<div class="card" style="margin-top:12px"><div class="mono">$ git clone ${esc(data.clone.name)}</div><div class="clone" style="margin-top:8px">${esc(data.clone.command)}</div><button class="btn small" id="copy-clone" type="button" style="margin-top:8px">Копировать</button></div>` : ""}
      </div>
    </div>`;
  root.querySelector("#find").addEventListener("click", openPalette);
  root.querySelector("#new-repo").addEventListener("click", () => createRepo());
  root.querySelector("#copy-clone")?.addEventListener("click", () => copy(data.clone.command));
  root.querySelector("#rerun")?.addEventListener("click", async () => {
    await post(`/api/repos/${attention.owner}/${attention.name}/ci`, { ref: attention.ref });
    location.hash = `#/r/${attention.owner}/${attention.name}/ci/${attention.id}`;
  });
}

function linkBanner(link) {
  if (link.conflict) {
    return `<div class="banner bad"><b>Зеркало разошлось с домашней копией</b><div class="muted">${link.conflict} репозиториев ждут решения. Force-push показывает, какие коммиты будут потеряны.</div></div>`;
  }
  if (link.phase === "offline" || link.queue) {
    return `<div class="banner"><b>Работаем дома. Зеркало подождёт</b><div class="muted">В очереди ${link.queue || 0}.</div><div class="q">${queueDots(link.jobs)}</div></div>`;
  }
  return "";
}

function weekValues(days) {
  const src = Array.isArray(days) ? days.map((value) => {
    const count = Number(value);
    return Number.isFinite(count) && count > 0 ? count : 0;
  }) : [];
  if (src.length > 7) return src.slice(-7);
  if (src.length === 7) return src;
  return Array(7 - src.length).fill(0).concat(src);
}

function weekChart(week, labels) {
  const all = week || [];
  const series = all.slice(0, 8);
  const rows = series.map((repo) => weekValues(repo.days));
  const max = Math.max(1, ...rows.flat());
  const width = 700;
  const height = 100;
  const yOf = (count) => 16 + (1 - count / max) * 70;
  const body = series.map((repo, index) => {
    const values = rows[index];
    const total = values.reduce((sum, count) => sum + count, 0);
    const points = values.map((count, day) => {
      const x = ((day + 0.5) / 7) * width;
      return `${x.toFixed(1)},${yOf(count).toFixed(1)}`;
    }).join(" ");
    const dots = values.map((count) => count
      ? `<span><i class="pt" style="--y:${yOf(count).toFixed(1)}%" title="${count}"></i></span>`
      : "<span></span>").join("");
    const line = total
      ? `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" aria-hidden="true"><polyline points="${points}"></polyline></svg><div class="week-cols">${dots}</div>`
      : "";
    const spoken = total ? `${total} за неделю` : "нет коммитов за неделю";
    return `<div class="week-row s${index}${total ? "" : " is-empty"}">
      <div class="week-name" title="${esc(repo.name)}"><i class="swatch"></i><b>${esc(repo.name)}</b><em>${total}</em></div>
      <div class="week-plot" role="img" aria-label="${esc(repo.name)}: ${spoken}">${line}</div>
    </div>`;
  }).join("");
  const axis = (labels || []).slice(0, 7).map((label) => `<span>${esc(label)}</span>`).join("");
  const more = all.length > series.length ? `<div class="tiny">ещё ${all.length - series.length}</div>` : "";
  return `<div class="week">${body}<div class="week-axis"><span></span><div class="days">${axis}</div></div>${more}</div>`;
}

function attentionHref(item) {
  if (item.kind === "ci") return `#/r/${item.owner}/${item.name}/ci/${item.id}`;
  if (item.kind === "pr") return `#/r/${item.owner}/${item.name}/pull/${item.number}`;
  return `#/r/${item.owner}/${item.name}`;
}

function repoCard(repo) {
  return `<a class="card repo-card" href="#/r/${esc(repo.owner)}/${esc(repo.name)}">
    <header><b>${esc(repo.name)}</b> ${repo.version ? `<span class="pill">${esc(repo.version)}</span>` : ""}</header>
    <div class="meta">${esc(repo.language || "репозиторий")}</div>
    <div style="margin-top:10px">${esc(repo.subject || repo.description || "")}</div>
    <div class="meta" style="margin-top:10px">${statusDot(repo.status)} ${esc(repo.branch)} · ${esc(ago(repo.updatedAt))}</div>
    <div class="meta">${esc(statusLine(repo))}</div>
  </a>`;
}

function statusLine(repo) {
  if (repo.status === "failed") return "сборка упала";
  if (repo.status === "conflict" || repo.mirrorStatus === "conflict") return "зеркало разошлось";
  if (repo.status === "ahead" || repo.mirrorStatus === "ahead") return "есть неотправленное";
  if (repo.status === "offline") return "зеркало недоступно";
  if (repo.status === "local" || repo.mirrorMode === "local") return "только локально";
  return "синхр. с GitHub";
}

function summaryMirrorHint(data) {
  if (!data.mirrorUrl || !data.mirrorMode || data.mirrorMode === "local") return "";
  return `<div class="tiny">После слияния основная ветка встанет в очередь зеркала.</div>`;
}

function brief(text) {
  const lines = String(text || "").split("\n").map((line) => line.trim()).filter(Boolean);
  const useful = lines.find((line) => /error|failed|pyside|msvc|не установ/i.test(line)) || lines[0] || "";
  return useful.replace(/^echo\s+/, "").replace(/^["']|["']$/g, "").slice(0, 180);
}

function activity(item) {
  return `<a class="item" href="#/r/${esc(item.owner)}/${esc(item.name)}/commit/${esc(item.sha)}"><span class="mono">${esc(item.short)}</span><span class="grow">${esc(item.subject)}</span>${item.tag ? `<span class="pill">${esc(item.tag)}</span>` : ""}</a>`;
}

function createRepo() {
  const wrap = document.createElement("div");
  wrap.className = "modal";
  wrap.innerHTML = `<form class="dialog" id="form"><h2>Новый репозиторий</h2>
    <input class="field" name="name" placeholder="Имя" required style="margin-top:12px">
    <textarea class="field" name="description" placeholder="Коротко, зачем он" style="margin-top:8px"></textarea>
    <div class="row" style="margin-top:12px"><button class="btn" type="submit">Создать</button><button class="btn ghost" type="button" id="cancel">Отмена</button></div></form>`;
  document.body.appendChild(wrap);
  wrap.querySelector("#cancel").onclick = () => wrap.remove();
  wrap.querySelector("#form").onsubmit = async (event) => {
    event.preventDefault();
    const data = new FormData(event.target);
    const created = await post("/api/repos", { name: data.get("name"), description: data.get("description") });
    wrap.remove();
    location.hash = `#/r/${created.repo.owner}/${created.repo.name}`;
  };
}

async function repoList(root) {
  const repos = await get("/api/repos");
  root.innerHTML = pageHead("Репозитории", "", `<button class="btn" id="new-repo" type="button">+ Новый репозиторий</button>`) +
    `<div class="card">${repos.map((repo) => `<a class="commit-row" href="#/r/${esc(repo.owner)}/${esc(repo.name)}"><b class="grow">${esc(repo.name)}</b><span class="muted">${esc(repo.description || "")}</span><span class="pill">${esc(modeLabel(repo.mirrorMode))}</span></a>`).join("") || `<div class="empty">Репозиториев пока нет</div>`}</div>`;
  root.querySelector("#new-repo").onclick = createRepo;
}

function tabs(owner, name, current) {
  const items = [["code", "Код"], ["commits", "Коммиты"], ["branches", "Ветки"], ["tags", "Теги"], ["pulls", "PR"], ["issues", "Задачи"], ["ci", "Сборки"], ["releases", "Релизы"]];
  return `<div class="tabs">${items.map(([id, label]) => `<a class="${current === id ? "active" : ""}" href="#/r/${owner}/${name}${id === "code" ? "" : "/" + id}">${label}</a>`).join("")}</div>`;
}

async function repo(root, owner, name, section, query) {
  const summary = await get(`/api/repos/${owner}/${name}`);
  const ref = query.get("ref") || summary.branch || summary.repo.defaultBranch;
  root.innerHTML = `
    <div class="tiny">${esc(owner)} / ${esc(name)}</div>
    <div class="top"><div><h1>${esc(name)} ${summary.repo.mirrorStatus === "synced" ? `<span class="pill ok">зеркало синхронизировано</span>` : summary.repo.mirrorMode === "local" ? `<span class="pill">только локально</span>` : ""}</h1></div>
      <div class="row"><button class="btn" id="clone" type="button">Клонировать</button></div></div>
    ${tabs(owner, name, section === "code" ? "code" : section)}
    <div id="body"></div>`;
  root.querySelector("#clone").onclick = () => cloneDialog(summary);
  const body = root.querySelector("#body");
  if (section === "commits") return commits(body, owner, name, ref);
  if (section === "branches" || section === "tags") return refs(body, owner, name, section);
  if (section === "pulls") return pulls(body, owner, name);
  if (section === "issues") return board(body, owner, name);
  if (section === "ci") return ciList(body, owner, name);
  if (section === "releases") return releaseList(body, owner, name);
  return code(body, summary, owner, name, ref, query.get("path") || "");
}

function cloneDialog(summary) {
  const wrap = document.createElement("div");
  wrap.className = "modal";
  wrap.innerHTML = `<div class="dialog"><h2>Клонировать ${esc(summary.repo.name)}</h2>
    <div class="tiny">SSH</div><div class="clone">${esc(summary.ssh)}</div>
    <div class="tiny" style="margin-top:8px">HTTPS</div><div class="clone">${esc(summary.http)}</div>
    <div class="row" style="margin-top:12px"><button class="btn" id="copy" type="button">Копировать SSH</button><button class="btn ghost" id="close" type="button">Закрыть</button></div></div>`;
  document.body.appendChild(wrap);
  wrap.querySelector("#close").onclick = () => wrap.remove();
  wrap.querySelector("#copy").onclick = () => copy("git clone " + summary.ssh);
}

async function code(root, summary, owner, name, ref, dir) {
  const [tree, readme, commits] = await Promise.all([
    get(`/api/repos/${owner}/${name}/tree?ref=${encodeURIComponent(ref)}&path=${encodeURIComponent(dir)}`),
    dir ? Promise.resolve(null) : get(`/api/repos/${owner}/${name}/readme?ref=${encodeURIComponent(ref)}`),
    dir ? Promise.resolve([]) : get(`/api/repos/${owner}/${name}/commits?ref=${encodeURIComponent(ref)}&limit=6`),
  ]);
  const refsData = await get(`/api/repos/${owner}/${name}/refs`);
  const history = (commits || []).map((item) => `<a href="#/r/${owner}/${name}/commit/${esc(item.sha)}">${statusDot("synced")}<span class="mono">${esc(item.short)}</span><span class="tiny">${esc(item.subject)}</span></a>`).join("");
  root.innerHTML = `<div class="layout"><div class="card">
      ${history ? `<div class="history">${history}</div>` : ""}
      <div class="row"><select class="field" id="ref" style="max-width:240px">${(refsData.branches || []).map((branch) => `<option ${branch.name === ref ? "selected" : ""}>${esc(branch.name)}</option>`).join("")}${(refsData.tags || []).map((tag) => `<option ${tag.name === ref ? "selected" : ""}>${esc(tag.name)}</option>`).join("")}</select>
      <span class="muted grow">${dir ? esc(dir) : "корень"}</span></div>
      ${tree.empty ? `<div class="empty">Репозиторий пуст. Первый push создаст main.</div><div class="clone">${esc(summary.clone)}</div>` : (tree.entries || []).map((entry) => `<button class="file-row" data-type="${esc(entry.type)}" data-path="${esc(entry.path)}" type="button">${icon(entry.type === "tree" ? "folder" : "file")} <span class="grow">${esc(entry.name)}</span></button>`).join("")}
      ${readme && !readme.missing ? `<div class="readme"><div class="tiny">${esc(readme.name)}</div><div class="md">${readme.html}</div></div>` : ""}
    </div>
    <aside>
      <div class="card side-block"><div class="tiny">О РЕПОЗИТОРИИ</div><div>${esc(summary.repo.description || "Без описания")}</div><div class="meta muted" style="margin-top:8px">${esc(summary.language || "")} ${summary.version ? `· ${esc(summary.version)}` : ""}</div></div>
      <div class="card side-block"><div class="tiny">ЗЕРКАЛО</div><div>${statusDot(summary.repo.mirrorStatus || summary.repo.mirrorMode)} ${esc(modeLabel(summary.repo.mirrorMode))}</div><div class="tiny">${esc(summary.repo.mirrorUrl || "не настроено")}</div></div>
      <div class="card side-block"><div class="tiny">SSH</div><div class="clone">${esc(summary.ssh)}</div></div>
    </aside></div>`;
  root.querySelector("#ref").onchange = (event) => { location.hash = `#/r/${owner}/${name}?ref=${encodeURIComponent(event.target.value)}`; };
  root.querySelectorAll(".file-row").forEach((row) => row.addEventListener("click", async () => {
    if (row.dataset.type === "tree") {
      location.hash = `#/r/${owner}/${name}?ref=${encodeURIComponent(ref)}&path=${encodeURIComponent(row.dataset.path)}`;
      return;
    }
    const blob = await get(`/api/repos/${owner}/${name}/blob?ref=${encodeURIComponent(ref)}&path=${encodeURIComponent(row.dataset.path)}`);
    const box = document.createElement("div");
    box.className = "blob";
    box.textContent = blob.binary ? "Бинарный файл" : blob.content;
    row.after(box);
  }));
}

async function commits(root, owner, name, ref) {
  const list = await get(`/api/repos/${owner}/${name}/commits?ref=${encodeURIComponent(ref)}`);
  root.innerHTML = `<div class="card">${list.map((item) => `<a class="commit-row" href="#/r/${owner}/${name}/commit/${esc(item.sha)}"><span class="mono">${esc(item.short)}</span><span class="grow">${esc(item.subject)}</span><span class="muted">${esc(item.author)}</span><span class="tiny">${esc(ago(item.date))}</span></a>`).join("") || `<div class="empty">Коммитов нет</div>`}</div>`;
}

async function refs(root, owner, name, kind) {
  const data = await get(`/api/repos/${owner}/${name}/refs`);
  const rows = kind === "tags" ? data.tags : data.branches;
  root.innerHTML = `<div class="card">${(rows || []).map((item) => `<a class="ref-row" href="#/r/${owner}/${name}?ref=${encodeURIComponent(item.name)}"><b class="grow">${esc(item.name)}</b><span class="mono">${esc(short(item.sha))}</span><span class="tiny">${esc(item.subject || "")}</span></a>`).join("") || `<div class="empty">Пока пусто</div>`}</div>`;
}

async function commit(root, owner, name, sha) {
  const data = await get(`/api/repos/${owner}/${name}/commits/${sha}`);
  const item = data.commit;
  root.innerHTML = `
    <div class="tiny">${esc(owner)} / ${esc(name)} / ${esc(short(item.sha))}</div>
    <div class="top"><div><h1>${esc(item.subject)}</h1><div class="sub">${esc(item.author)} · ${esc(ago(item.date))} · ${esc(short(item.sha))}</div></div>
      <div class="row"><button class="btn ghost small" id="mode" type="button">Раздельно</button><button class="btn" id="pick" type="button">Cherry-pick</button></div></div>
    <div id="files"></div>
    <div class="helpbar"><span>J / K следующий файл</span><span>C комментарий</span><span>Y ссылка</span></div>`;
  const holder = root.querySelector("#files");
  let split = false;
  const drawFiles = () => { holder.innerHTML = (data.files || []).map((file, index) => fileBlock(file, data.comments || [], split, index)).join("") || `<div class="empty">Пустой diff</div>`; bindDiff(holder, owner, name, `commit:${item.sha}`); };
  drawFiles();
  root.querySelector("#mode").onclick = (event) => { split = !split; event.target.textContent = split ? "Вместе" : "Раздельно"; drawFiles(); };
  root.querySelector("#pick").onclick = async () => { await post(`/api/repos/${owner}/${name}/commits/${item.sha}/cherry-pick`, {}); location.hash = `#/r/${owner}/${name}`; };
  installJK(holder);
}

function fileBlock(file, comments, split, index) {
  const notes = comments.filter((comment) => comment.path === file.path);
  const body = split ? splitHunks(file) : unifiedHunks(file);
  return `<article class="diff-file" data-file="${index}"><header><span class="mono">${esc(file.path)}</span><span class="tiny">+${file.additions} −${file.deletions}</span></header>${file.binary ? `<div class="empty">Бинарный файл</div>` : body}${notes.map((comment) => `<div class="comment-box"><b>${esc(comment.author)}</b><div>${esc(comment.body)}</div>${comment.suggestion ? `<pre class="mono">${esc(comment.suggestion)}</pre>` : ""}</div>`).join("")}</article>`;
}

function unifiedHunks(file) {
  return (file.hunks || []).map((hunk) => hunk.lines.map((line) => `<div class="diff-line ${line.kind === "add" ? "add" : line.kind === "del" ? "del" : ""}" data-path="${esc(file.path)}" data-line="${line.new || line.old || 0}"><span class="ln">${line.old || ""}</span><span class="ln">${line.new || ""}</span><span>${esc(line.text)}</span></div>`).join("")).join("");
}

function splitHunks(file) {
  return (file.hunks || []).map((hunk) => pair(hunk.lines).map((row) => `<div class="split-row"><span class="${row.left?.kind === "del" ? "del" : ""}">${row.left ? esc(row.left.text) : ""}</span><span class="${row.right?.kind === "add" ? "add" : ""}" data-path="${esc(file.path)}" data-line="${row.right?.new || row.left?.new || 0}">${row.right ? esc(row.right.text) : ""}</span></div>`).join("")).join("");
}

function pair(lines) {
  const rows = [];
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (line.kind === "ctx") { rows.push({ left: line, right: line }); index += 1; continue; }
    const dels = [];
    const adds = [];
    while (index < lines.length && lines[index].kind === "del") dels.push(lines[index++]);
    while (index < lines.length && lines[index].kind === "add") adds.push(lines[index++]);
    const count = Math.max(dels.length, adds.length, 1);
    for (let i = 0; i < count; i += 1) rows.push({ left: dels[i], right: adds[i] });
  }
  return rows;
}

function bindDiff(holder, owner, name, target) {
  holder.querySelectorAll("[data-line]").forEach((line) => {
    line.addEventListener("dblclick", () => compose(line, owner, name, target));
  });
}

function compose(line, owner, name, target) {
  if (line.nextElementSibling?.classList.contains("comment-box")) return;
  const box = document.createElement("div");
  box.className = "comment-box";
  box.innerHTML = `<textarea class="field" rows="3" placeholder="Комментарий. Правка — блоком \`\`\`suggestion"></textarea><div class="composer"><button class="btn small" type="button">Комментировать</button><button class="btn ghost small" type="button">Отмена</button></div>`;
  line.after(box);
  box.querySelector(".ghost").onclick = () => box.remove();
  box.querySelector(".btn.small").onclick = async () => {
    const endpoint = target.startsWith("pull:") ? `/api/repos/${owner}/${name}/pulls/${target.slice(5)}/comments` : `/api/repos/${owner}/${name}/commits/${target.slice(7)}/comments`;
    await post(endpoint, { path: line.dataset.path, line: Number(line.dataset.line), body: box.querySelector("textarea").value });
    location.reload();
  };
}

let diffKeys = null;
function installJK(holder) {
  if (diffKeys) window.removeEventListener("keydown", diffKeys);
  let index = 0;
  diffKeys = (event) => {
    if (!holder.isConnected) {
      window.removeEventListener("keydown", diffKeys);
      diffKeys = null;
      return;
    }
    if (event.target.matches("input, textarea")) return;
    const files = [...holder.querySelectorAll("[data-file]")];
    if (event.key === "j" || event.key === "J") index = Math.min(files.length - 1, index + 1);
    else if (event.key === "k" || event.key === "K") index = Math.max(0, index - 1);
    else if (event.key === "y" || event.key === "Y") { copy(location.href); return; }
    else if (event.key === "c" || event.key === "C") {
      const line = holder.querySelector("[data-line]");
      if (line) line.dispatchEvent(new Event("dblclick"));
      return;
    } else return;
    files[index]?.scrollIntoView({ block: "start", behavior: "smooth" });
  };
  window.addEventListener("keydown", diffKeys);
}

async function pulls(root, owner, name) {
  const list = await get(`/api/repos/${owner}/${name}/pulls`);
  root.innerHTML = `<div class="card">${list.map((item) => `<a class="commit-row" href="#/r/${owner}/${name}/pull/${item.number}"><span class="pill ${item.status === "open" ? "ok" : ""}">${esc(item.status)}</span><b class="grow">${esc(item.title)}</b><span class="mono">${esc(item.head)}</span></a>`).join("") || `<div class="empty">Открытых запросов нет</div>`}</div>`;
}

async function allPulls(root) {
  const repos = await get("/api/repos");
  const lists = await Promise.all(repos.map((repo) => get(`/api/repos/${repo.owner}/${repo.name}/pulls`).then((items) => items.map((item) => ({ ...item, owner: repo.owner, name: repo.name })))));
  const pullsFlat = lists.flat().filter((item) => item.status === "open");
  root.innerHTML = pageHead("Pull requests", `${pullsFlat.length} открыто`) + `<div class="card">${pullsFlat.map((item) => `<a class="commit-row" href="#/r/${item.owner}/${item.name}/pull/${item.number}"><b>${esc(item.name)}</b><span class="grow">${esc(item.title)}</span><span class="mono">${esc(item.head)}</span></a>`).join("") || `<div class="empty">Ревью не ждут</div>`}</div>`;
}

async function pull(root, owner, name, number) {
  const data = await get(`/api/repos/${owner}/${name}/pulls/${number}`);
  const item = data.pull;
  root.innerHTML = `
    <div class="tiny">${esc(owner)} / ${esc(name)} / PR #${esc(number)}</div>
    <div class="top"><div><h1>${esc(item.title)} <span class="pill ${item.status === "open" ? "ok" : ""}">${esc(item.status)}</span></h1>
      <div class="sub">${esc(item.head)} → ${esc(item.base)} · ${data.mergeable ? "конфликтов нет" : "слияние конфликтует"} · ${data.linear ? "линейная история возможна" : "нужен merge-коммит"}</div></div></div>
    ${data.mergeable ? "" : `<div class="banner bad">Ветки разошлись. Слияние остановится, пока конфликт не разрешён в рабочей копии.</div>`}
    <div class="layout"><div>
      <div class="row" style="margin-bottom:8px"><span class="muted">${data.files.length} файлов</span><button class="btn ghost small" id="mode" type="button">Раздельно</button></div>
      <div id="files"></div>
      <div class="helpbar"><span>J / K файлы</span><span>двойной клик — комментарий</span></div>
    </div>
    <aside>
      <div class="card"><div class="tiny">РЕВЬЮ</div><div class="review-count" id="review-count">${data.unresolved ? `${data.unresolved} незакрытых` : "замечаний нет"}</div><div class="tiny">Сборка ${esc(data.ci || "—")}</div></div>
      ${item.status === "open" ? `<div class="card" style="margin-top:12px"><div class="chips" id="methods"><button class="chip" data-method="squash">squash</button><button class="chip" data-method="rebase">rebase</button><button class="chip on" data-method="merge">merge-коммит</button></div><button class="btn green" id="merge" type="button" style="width:100%;margin-top:10px" ${data.mergeable ? "" : "disabled"}>Слить в ${esc(item.base)}</button>${summaryMirrorHint(data)}<div class="tiny">$ el pr checkout ${esc(number)}</div></div>` : `<div class="card" style="margin-top:12px">Слито ${esc(short(item.mergeSha))}</div>`}
    </aside></div>`;
  const holder = root.querySelector("#files");
  let split = false;
  let method = "merge";
  const drawFiles = () => { holder.innerHTML = (data.files || []).map((file, index) => fileBlock(file, data.comments || [], split, index)).join(""); bindDiff(holder, owner, name, `pull:${number}`); };
  drawFiles();
  installJK(holder);
  root.querySelector("#mode").onclick = (event) => { split = !split; event.target.textContent = split ? "Вместе" : "Раздельно"; drawFiles(); };
  root.querySelectorAll(".chip").forEach((chip) => chip.addEventListener("click", () => {
    method = chip.dataset.method;
    root.querySelectorAll(".chip").forEach((item) => item.classList.toggle("on", item === chip));
  }));
  root.querySelector("#merge")?.addEventListener("click", async (event) => {
    const button = event.currentTarget;
    button.disabled = true;
    button.innerHTML = `<i class="spin"></i> Слияние`;
    try {
      await post(`/api/repos/${owner}/${name}/pulls/${number}/merge`, { method });
      const mirrored = data.mirrorUrl && data.mirrorMode && data.mirrorMode !== "local";
      toast(mirrored ? `${item.base} встал в очередь зеркала` : `Слито в ${item.base}`, "ok", 1500);
      location.reload();
    } catch (error) {
      button.disabled = false;
      button.textContent = `Слить в ${item.base}`;
      toast(error.message, "bad", 4000);
    }
  });
  root.querySelectorAll(".comment-box").forEach((box) => {
    const id = (data.comments || []).find((comment) => box.textContent.includes(comment.body))?.id;
    if (!id || item.status !== "open") return;
    if ((data.comments || []).find((comment) => comment.id === id)?.resolved) {
      box.remove();
      return;
    }
    const bar = document.createElement("div");
    bar.className = "composer";
    bar.innerHTML = `<button class="btn ghost small" type="button" data-resolve="${id}">Решено</button>` + ((data.comments || []).find((comment) => comment.id === id)?.suggestion ? `<button class="btn small" type="button" data-apply="${id}">Применить правку</button>` : "");
    box.append(bar);
  });
  root.querySelectorAll("[data-resolve]").forEach((button) => button.addEventListener("click", async () => {
    const box = button.closest(".comment-box");
    box?.classList.add("resolved");
    const counter = root.querySelector("#review-count");
    if (counter) {
      const current = Number.parseInt(counter.textContent, 10);
      counter.textContent = current > 1 ? `${current - 1} незакрытых` : "замечаний нет";
      counter.classList.add("flash");
    }
    await new Promise((resolve) => setTimeout(resolve, window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 120 : 420));
    await post(`/api/comments/${button.dataset.resolve}/resolve`, {});
  }));
  root.querySelectorAll("[data-apply]").forEach((button) => button.addEventListener("click", async () => {
    await post(`/api/comments/${button.dataset.apply}/apply`, {});
    location.reload();
  }));
}

async function board(root, owner, name) {
  const query = owner ? "" : "";
  const issues = await get(owner ? `/api/repos/${owner}/${name}/issues` : "/api/issues");
  const columns = [["backlog", "Бэклог"], ["progress", "В работе"], ["review", "На ревью"], ["done", "Готово"]];
  const head = owner ? "" : pageHead("Задачи", "Доска по всем репозиториям", `<button class="btn" id="add" type="button">+ Задача</button>`);
  const empty = issues.length ? "" : `<section class="card empty-state"><h2>Задач пока нет</h2><p class="muted">Карточка появится здесь и уедет в «Готово», когда коммит с номером задачи сольётся в основную ветку.</p></section>`;
  root.innerHTML = head + empty + `<div class="row" style="margin-bottom:12px"><input class="field" id="q" placeholder="is:open label:дизайн" style="max-width:360px"></div>
    <div class="kanban">${columns.map(([id, label]) => `<section class="card column" data-status="${id}"><b>${label}</b> <span class="tiny">${issues.filter((item) => item.status === id).length}</span>${issues.filter((item) => item.status === id).map(issueCard).join("")}</section>`).join("")}</div>
    <div class="tiny" style="margin-top:12px">Закрывается из коммита: fix: сокеты #12 — задача переезжает в «Готово» после слияния в main.</div>`;
  root.querySelector("#q")?.addEventListener("change", async (event) => {
    const filtered = await get((owner ? `/api/repos/${owner}/${name}/issues?q=` : "/api/issues?q=") + encodeURIComponent(event.target.value));
    root.querySelectorAll(".column").forEach((column) => {
      column.querySelectorAll(".issue").forEach((node) => node.remove());
      filtered.filter((item) => item.status === column.dataset.status).forEach((item) => column.insertAdjacentHTML("beforeend", issueCard(item)));
    });
  });
  root.querySelectorAll(".column").forEach((column) => {
    column.addEventListener("dragover", (event) => event.preventDefault());
    column.addEventListener("drop", async (event) => {
      const id = event.dataTransfer.getData("text/plain");
      await api("PATCH", `/api/issues/${id}`, { status: column.dataset.status });
      location.reload();
    });
  });
  root.querySelectorAll(".issue").forEach((card) => {
    card.addEventListener("dragstart", (event) => event.dataTransfer.setData("text/plain", card.dataset.id));
  });
  root.querySelector("#add")?.addEventListener("click", () => newIssue(owner, name));
}

function issueCard(item) {
  return `<article class="issue" draggable="true" data-id="${item.id}"><b>${esc(item.title)}</b><div class="tiny">#${item.number} ${esc(item.name)} ${(item.labels || []).map((label) => `<span class="pill">${esc(label)}</span>`).join(" ")}</div></article>`;
}

async function newIssue(owner, name) {
  let target = owner ? { owner, name } : null;
  if (!target) {
    const repos = await get("/api/repos");
    target = repos[0];
  }
  if (!target) return;
  const title = prompt("Задача");
  if (!title) return;
  await post(`/api/repos/${target.owner}/${target.name}/issues`, { title, status: "backlog" });
  location.reload();
}

async function ciList(root, owner, name) {
  const runs = await get(owner ? `/api/repos/${owner}/${name}/ci` : "/api/ci");
  const head = owner ? "" : pageHead("Сборки", "GitHub Actions-совместимые workflow на этой машине");
  root.innerHTML = head + `<div class="card">${runs.map((run) => `<a class="commit-row" href="#/r/${runHref(run)}/ci/${run.id}"><span class="pill ${run.status === "success" ? "ok" : run.status === "failure" ? "bad" : ""}">${esc(run.status)}</span><b class="grow">${esc(run.workflow)}</b><span class="mono">${esc(run.ref)}</span><span class="tiny">${esc(ago(run.finishedAt || run.startedAt))}</span></a>`).join("") || `<div class="empty">Сборок ещё не было</div>`}</div>`;
}

function runHref(run) {
  if (run.repo) return run.repo;
  return "eugene/repo";
}

async function ciRun(root, owner, name, id) {
  const run = await get(`/api/ci/${id}`);
  let jobs = [];
  try { jobs = JSON.parse(run.jobs || "[]"); } catch { jobs = []; }
  root.innerHTML = `
    <div class="top"><div><h1>${run.status === "failure" ? "Сборка упала" : esc(run.workflow)}</h1><div class="sub">${esc(run.ref)} · ${esc(short(run.sha))}</div></div>
      <button class="btn" id="rerun" type="button">Перезапустить</button></div>
    <div class="jobs">${jobs.map((job, index) => `<button class="card job" data-job="${index}" type="button"><div class="kicker ${job.status === "failure" ? "bad" : "ok"}">${esc(job.status)}</div><b>${esc(job.name)}</b><div class="tiny">${esc(job.runsOn || "")}</div></button>`).join("")}</div>
    <div class="layout"><pre class="log" id="log"></pre><aside class="card"><div class="kicker bad">Почему упало</div><div style="margin-top:8px">${esc(run.reason || "Сборка прошла.")}</div><div class="tiny" style="margin-top:10px">Команды run: выполняются локально. actions/checkout пропускается, остальные uses помечаются в логе.</div></aside></div>`;
  const log = root.querySelector("#log");
  const show = (text) => { log.innerHTML = esc(text).replace(/error.*/gi, (line) => `<span class="err">${line}</span>`); };
  show(jobs[0]?.log || run.log || "");
  root.querySelectorAll(".job").forEach((job) => job.addEventListener("click", () => show(jobs[job.dataset.job].log)));
  root.querySelector("#rerun").onclick = async (event) => {
    const button = event.currentTarget;
    button.disabled = true;
    button.innerHTML = `<i class="spin"></i> Запуск`;
    toast("Сборка идёт", "amb", 4000);
    await post(`/api/repos/${owner}/${name}/ci`, { ref: run.ref });
    location.hash = `#/r/${owner}/${name}/ci`;
  };
}

async function releaseList(root, owner, name) {
  const repos = owner ? [{ owner, name }] : await get("/api/repos");
  const groups = [];
  for (const repo of repos) {
    const items = await get(`/api/repos/${repo.owner}/${repo.name}/releases`);
    items.forEach((item) => groups.push({ ...item, owner: repo.owner, name: repo.name }));
  }
  const current = groups[0];
  root.innerHTML = `
    ${owner ? "" : pageHead("Релизы", "Заметки из CHANGELOG и коммитов с прошлого тега")}
    <div class="layout">
      <div class="card">${current ? `<div class="kicker ok">${esc(current.name)} · ${current.published ? "опубликован" : "локальный"}</div><h1>${esc(current.tag)}</h1><div class="md" style="white-space:pre-wrap">${esc(current.notes)}</div>
        ${(current.assets || []).map((asset) => `<div class="commit-row"><span class="grow">${esc(asset.name)}</span><a href="/api/assets/${asset.id}">SHA-256 ${esc(asset.sha256.slice(0, 12))}</a></div>`).join("")}` : `<div class="empty-state"><h2>Релизов нет</h2><p class="muted">Заметки соберутся из CHANGELOG и коммитов с прошлого тега.</p></div>`}
        <div style="margin-top:8px">${groups.slice(1).map((item) => `<a class="commit-row" href="#/r/${item.owner}/${item.name}/releases"><span class="mono">${esc(item.tag)}</span><span>${esc(item.name)}</span></a>`).join("")}</div>
      </div>
      <form class="card" id="rel"><h2>Новый релиз</h2><div class="tiny">Заметки соберутся сами, если оставить поле пустым.</div>
        <input class="field" name="repo" placeholder="owner/name" value="${owner ? `${esc(owner)}/${esc(name)}` : ""}" style="margin-top:8px" required>
        <input class="field" name="tag" placeholder="v0.4.1" style="margin-top:8px" required>
        <textarea class="field" name="notes" rows="5" style="margin-top:8px" placeholder="Пусто — взять CHANGELOG и коммиты"></textarea>
        <label class="tiny"><input type="checkbox" name="fromCi"> файлы последней зелёной сборки</label>
        <label class="tiny"><input type="checkbox" name="publish"> опубликовать и на зеркало</label>
        <button class="btn" style="margin-top:10px;width:100%" type="submit">+ Новый релиз</button>
        <div class="tiny">$ el release v0.4.1 --from-ci</div></form>
    </div>`;
  root.querySelector("#rel").onsubmit = async (event) => {
    event.preventDefault();
    const data = new FormData(event.target);
    const [repoOwner, repoName] = String(data.get("repo")).split("/");
    await post(`/api/repos/${repoOwner}/${repoName}/releases`, {
      tag: data.get("tag"), notes: data.get("notes"), fromCi: data.get("fromCi") === "on", publish: data.get("publish") === "on",
    });
    location.hash = `#/r/${repoOwner}/${repoName}/releases`;
    location.reload();
  };
}

async function settings(root, tab) {
  const [settingsData, repos, keys, backups] = await Promise.all([get("/api/settings"), get("/api/repos"), get("/api/keys"), get("/api/backups")]);
  const tabs = [["server", "Сервер"], ["keys", "SSH-ключи"], ["mirrors", "Зеркала"], ["backups", "Резервные копии"], ["runner", "Раннеры"], ["token", "Токены"]];
  root.innerHTML = `<div class="tiny">Настройки</div><h1>Синхронизация</h1>
    <div class="tabs">${tabs.map(([id, label]) => `<a class="${tab === id ? "active" : ""}" href="#/settings/${id}">${label}</a>`).join("")}</div>
    <div id="panel"></div>`;
  const panel = root.querySelector("#panel");
  if (tab === "keys") return keysView(panel, keys);
  if (tab === "backups") return backupView(panel, settingsData, backups);
  if (tab === "server") return serverView(panel, settingsData);
  if (tab === "runner") return runnerView(panel, settingsData);
  if (tab === "token") return tokenView(panel, settingsData);
  return mirrorsView(panel, repos);
}

async function mirrorsView(root, repos) {
  const conflict = repos.filter((repo) => repo.mirrorStatus === "conflict");
  const offline = repos.filter((repo) => repo.mirrorStatus === "offline");
  const scene = conflict.length ? "conflict" : offline.length ? "offline" : "synced";
  const title = scene === "conflict" ? "Зеркало ушло вперёд" : scene === "offline" ? "Изменения ждут в очереди" : "Дом и GitHub в одном состоянии";
  root.innerHTML = `<div class="grid-2"><div class="card" data-sync-scene data-state="${scene}"><div class="sync-scene">${syncArt(scene)}<div class="node" style="left:8%;top:48px">${disk()}<b>Дом</b></div><div class="node" style="right:8%;top:36px">${cloud()}<b>Зеркало</b></div></div><div class="q"></div></div>
    <div class="card"><div class="kicker ${scene === "conflict" ? "bad" : scene === "offline" ? "" : "ok"}">${esc(title)}</div><p class="muted" data-sync-counts></p><p class="muted">${scene === "conflict" ? "Обычный push не перепишет чужие коммиты. Список потерянных коммитов показывается до подтверждения." : "Push уходит при слиянии в основную ветку. Если сети нет, задание остаётся в очереди."}</p></div></div>
    <div class="card" style="margin-top:12px"><table><thead><tr><th>Репозиторий</th><th>Зеркало</th><th>Режим</th><th>Состояние</th></tr></thead><tbody>
      ${repos.map((repo) => `<tr><td><a href="#/r/${esc(repo.owner)}/${esc(repo.name)}">${esc(repo.name)}</a></td><td class="mono">${esc(repo.mirrorUrl || "—")}</td><td><select data-repo="${esc(repo.owner)}/${esc(repo.name)}" class="field">${["local", "push", "both"].map((mode) => `<option value="${mode}" ${repo.mirrorMode === mode ? "selected" : ""}>${esc(modeLabel(mode))}</option>`).join("")}</select></td><td>${statusDot(repo.mirrorStatus || repo.mirrorMode)} ${esc(repo.mirrorDetail || repo.mirrorStatus || "")}</td></tr>`).join("")}
    </tbody></table></div>
    <div class="card" style="margin-top:12px"><h2>Force-push</h2><div class="row"><input class="field" id="repo" placeholder="owner/name"><button class="btn ghost" id="preview" type="button">Показать потерянные коммиты</button></div><div id="lost"></div></div>`;
  root.querySelectorAll("select").forEach((select) => select.addEventListener("change", async () => {
    const [owner, name] = select.dataset.repo.split("/");
    await api("PATCH", `/api/repos/${owner}/${name}`, { mirrorMode: select.value });
  }));
  root.querySelector("#preview").onclick = async () => {
    const [owner, name] = root.querySelector("#repo").value.split("/");
    try {
      const data = await get(`/api/repos/${owner}/${name}/mirror/preview?ref=refs/heads/main`);
      const lost = data.lost || [];
      root.querySelector("#lost").innerHTML = lost.length ? `${lost.map((item) => `<div class="commit-row"><span class="mono">${esc(short(item.sha))}</span>${esc(item.subject)}</div>`).join("")}<button class="btn" id="force" type="button">Всё равно перезаписать</button>` : `<div class="empty">Терять нечего, обычный push достаточен.</div>`;
      root.querySelector("#force")?.addEventListener("click", async () => {
        await post(`/api/repos/${owner}/${name}/mirror/push`, { ref: "refs/heads/main", force: true, confirm: true, lost: lost.map((item) => item.sha) });
        location.reload();
      });
    } catch (error) {
      if (error.payload?.lost) {
        root.querySelector("#lost").textContent = error.message;
      } else root.querySelector("#lost").textContent = error.message;
    }
  };
}

function keysView(root, keys) {
  root.innerHTML = `<div class="card">${keys.map((key) => `<div class="commit-row"><b class="grow">${esc(key.title)}</b><span class="mono">${esc(key.fingerprint)}</span><button class="btn ghost small" data-id="${key.id}" type="button">Удалить</button></div>`).join("") || `<div class="empty">Добавьте открытый ключ, иначе SSH-push не примется.</div>`}
    <form id="key" class="row" style="margin-top:12px"><input class="field" name="title" placeholder="Название"><textarea class="field" name="key" placeholder="ssh-ed25519 AAAA…"></textarea><button class="btn" type="submit">Добавить</button></form></div>`;
  root.querySelector("#key").onsubmit = async (event) => {
    event.preventDefault();
    const data = new FormData(event.target);
    await post("/api/keys", { title: data.get("title"), key: data.get("key") });
    location.reload();
  };
  root.querySelectorAll("[data-id]").forEach((button) => button.addEventListener("click", async () => {
    await api("DELETE", `/api/keys/${button.dataset.id}`);
    location.reload();
  }));
}

function backupView(root, settingsData, backups) {
  root.innerHTML = `<div class="card"><h2>git bundle каждую ночь</h2><div class="tiny">Каталог ${esc(settingsData.backupDir)} · время ${esc(settingsData.backupTime)}</div>
    <button class="btn" id="now" type="button" style="margin-top:10px">Сделать сейчас</button>
    ${(backups || []).map((item) => `<div class="commit-row"><span class="mono grow">${esc(item.path)}</span><span class="tiny">${esc(item.sha256.slice(0, 12))}</span></div>`).join("")}</div>`;
  root.querySelector("#now").onclick = async () => { await post("/api/backups", {}); location.reload(); };
}

function serverView(root, settingsData) {
  root.innerHTML = `<form class="card" id="form"><div class="row"><label class="grow">Имя<input class="field" name="displayName" value="${esc(settingsData.displayName)}"></label><label class="grow">Время бэкапа<input class="field" name="backupTime" value="${esc(settingsData.backupTime)}"></label></div>
    <label>Каталог бэкапа<input class="field" name="backupDir" value="${esc(settingsData.backupDir)}"></label>
    <label>Имя в URL<input class="field" name="advertiseHost" value="${esc(settingsData.advertiseHost || "")}" placeholder="127.0.0.1"></label>
    <div class="tiny">HTTP ${esc(settingsData.http)} · SSH ${esc(settingsData.sshPort)}. По умолчанию сервер слушает только localhost.</div>
    <button class="btn" type="submit">Сохранить</button></form>`;
  root.querySelector("#form").onsubmit = async (event) => {
    event.preventDefault();
    const data = new FormData(event.target);
    await api("PUT", "/api/settings", { displayName: data.get("displayName"), backupTime: data.get("backupTime"), backupDir: data.get("backupDir"), advertiseHost: data.get("advertiseHost") });
    location.reload();
  };
}

function runnerView(root, settingsData) {
  root.innerHTML = `<div class="card"><h2>Локальный раннер</h2><p>Workflow из <span class="mono">.github/workflows</span> запускаются на машине, где работает <span class="mono">el serve</span>. Это может быть Mac или Windows.</p><div class="tiny">${esc(settingsData.bind || settingsData.http)}</div></div>`;
}

function tokenView(root, settingsData) {
  root.innerHTML = `<form class="card" id="form"><h2>GitHub-токен</h2><p class="muted">Нужен только чтобы создать Release через API. Тег на зеркало уходит и без токена. ${settingsData.githubTokenSet ? "Токен сохранён." : "Токен не задан."}</p>
    <input class="field" name="githubToken" type="password" placeholder="github_pat_…"><div class="row" style="margin-top:8px"><button class="btn" type="submit">Сохранить</button><button class="btn ghost" id="clear" type="button">Забыть</button></div></form>`;
  root.querySelector("#form").onsubmit = async (event) => {
    event.preventDefault();
    await api("PUT", "/api/settings", { githubToken: new FormData(event.target).get("githubToken") });
    location.reload();
  };
  root.querySelector("#clear").onclick = async () => { await api("PUT", "/api/settings", { clearToken: true }); location.reload(); };
}

async function architecture(root) {
  const meta = await get("/api/meta");
  const link = await get("/api/sync");
  const scene = link.conflict ? "conflict" : (link.phase === "offline" || link.queue) ? "offline" : "online";
  root.innerHTML = `<div class="top"><div><h1>EL Workspace — как устроено</h1><div class="sub">Всё живёт дома. GitHub — только зеркало, а не источник правды.</div></div><span class="pill ${scene === "online" ? "ok" : scene === "conflict" ? "bad" : "warn"}">${scene === "online" ? "Зеркало на связи" : scene === "conflict" ? "Зеркало разошлось" : "Зеркало подождёт"}</span></div>
    <div class="arch" data-sync-scene data-state="${scene === "online" ? "synced" : scene}">
      <svg class="links ${scene}" viewBox="0 0 100 100" preserveAspectRatio="none">
        <path d="M22 62 C 32 62, 36 55, 46 52"></path>
        <path d="M40 28 C 44 36, 46 42, 48 48"></path>
        <path d="M58 48 C 66 40, 70 28, 74 22"></path>
        <path d="M58 55 C 68 58, 74 64, 78 66"></path>
      </svg>
      ${node(8, 220, "MacBook", "клиент · меню-бар · el CLI", laptop())}
      ${node(30, 40, "Backup-диск", "git bundle каждую ночь", disk())}
      ${node(38, 180, "Сервер EL", esc(meta.http), server())}
      ${node(62, 20, "GitHub", scene === "offline" ? `в очереди ${link.queue}` : "зеркало · push при слиянии", cloud())}
      ${node(70, 230, "Windows ПК", "трей · раннер CI", pc())}
    </div>
    <div class="facts">
      <div class="card"><b>Сервер — главная копия</b><p class="muted">Клиенты ходят по SSH и smart HTTP. История хранится в bare-репозиториях.</p></div>
      <div class="card"><b>Офлайн — не беда</b><p class="muted">Push в зеркало копится в очереди и уходит, когда связь вернётся.</p></div>
      <div class="card"><b>Бэкап каждую ночь</b><p class="muted">git bundle всех репозиториев пишется в выбранный каталог.</p></div>
    </div>`;
}

function syncArt(scene) {
  const klass = scene === "synced" ? "online" : scene;
  return `<svg class="links ${klass}" viewBox="0 0 100 40" preserveAspectRatio="none"><path d="M22 22 C 40 22, 60 16, 78 16"></path></svg>`;
}

function node(x, y, title, text, picture) {
  return `<div class="node" style="left:${x}%;top:${y}px">${picture}<b>${title}</b><div class="tiny">${text}</div></div>`;
}
function laptop() { return `<svg viewBox="0 0 120 70"><rect x="18" y="8" width="84" height="48" rx="6" fill="#d5dde8"/><rect x="24" y="14" width="72" height="36" rx="3" fill="#73a5ff"/><path d="M10 60h100l-8 8H18z" fill="#9aa8be"/></svg>`; }
function disk() { return `<svg viewBox="0 0 120 70"><rect x="20" y="16" width="80" height="40" rx="8" fill="#c5ceda"/><circle cx="78" cy="36" r="6" fill="#73a5ff"/></svg>`; }
function server() { return `<svg viewBox="0 0 120 70"><rect x="28" y="8" width="64" height="54" rx="8" fill="#dfe6f0"/><rect x="36" y="18" width="48" height="8" rx="2" fill="#73a5ff"/><rect x="36" y="32" width="48" height="8" rx="2" fill="#9eb6de"/></svg>`; }
function cloud() { return `<svg viewBox="0 0 120 70"><ellipse cx="60" cy="38" rx="34" ry="18" fill="#f4f7fb"/><ellipse cx="42" cy="36" rx="18" ry="14" fill="#f4f7fb"/><ellipse cx="74" cy="32" rx="20" ry="16" fill="#f4f7fb"/></svg>`; }
function pc() { return `<svg viewBox="0 0 120 70"><rect x="16" y="10" width="58" height="40" rx="4" fill="#10192f" stroke="#73a5ff"/><rect x="82" y="16" width="22" height="40" rx="3" fill="#c5ceda"/></svg>`; }

async function panel(root) {
  let data;
  try {
    data = await get("/api/panel");
  } catch (error) {
    root.innerHTML = `<section class="panel">
      <div class="row"><span class="dot bad"></span><div><b>Сервер недоступен</b><div class="tiny">${esc(error.message)}</div></div></div>
      <div class="row" style="margin-top:12px"><button class="btn" id="retry" type="button">Повторить</button></div>
    </section>`;
    root.querySelector("#retry").onclick = () => location.reload();
    return;
  }
  const backup = data.backup || {};
  const link = data.link || {};
  const offline = link.phase === "offline" || link.queue;
  const conflict = link.phase === "conflict" || link.conflict;
  const title = conflict ? "Зеркало разошлось" : offline ? "GitHub недоступен" : "Сервер работает";
  root.innerHTML = `<section class="panel">
    <div class="row"><span class="dot ${conflict ? "bad" : offline ? "warn" : "ok"}"></span><div><b>${title}</b><div class="tiny">${esc(data.host)} · ssh :${esc(data.sshPort)}</div></div></div>
    ${offline || conflict ? `<div class="q">${queueDots(link.jobs)}</div>` : ""}
    <div class="stats" style="margin-top:12px"><div class="stat"><span class="tiny">Зеркало</span><b>${conflict ? "конфликт" : data.queue ? "очередь" : "синхр."}</b></div><div class="stat"><span class="tiny">Очередь</span><b>${data.queue || "пуста"}</b></div><div class="stat"><span class="tiny">Бэкап</span><b>${esc(backup.time || backup.label || "")}</b></div></div>
    <div class="tiny" style="margin-top:12px">СЕЙЧАС</div>
    ${(data.items || []).map((item) => `<div class="notice">${statusDot(item.kind === "ci" ? "failed" : item.kind === "pr" ? "synced" : "warn")}<div class="grow"><b>${esc(item.title)}</b><div class="tiny">${esc(brief(item.detail || ""))}</div></div><a href="${item.kind === "pr" ? `#/r/${item.owner}/${item.name}/pull/${item.number}` : item.kind === "ci" ? `#/r/${item.owner}/${item.name}/ci/${item.id}` : `#/r/${item.owner}/${item.name}`}">${esc(item.action || "Открыть")}</a></div>`).join("")}
    <div class="tiny">НЕДАВНИЕ</div>
    ${(data.recent || []).map((repo) => `<div class="notice">${statusDot(repo.status)}<span class="grow">${esc(repo.name)}</span><span class="mono">${esc(repo.branch)}</span></div>`).join("")}
    <div class="row" style="margin-top:12px"><a class="btn grow" href="#/" style="text-align:center">Открыть EL Workspace</a><button class="btn ghost" id="close-panel" type="button">Синхр.</button></div>
  </section>`;
  root.querySelector("#close-panel")?.addEventListener("click", () => {
    const card = root.querySelector(".panel");
    card?.classList.add("out");
    setTimeout(() => { location.hash = "#/settings/mirrors"; }, window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 120 : 200);
  });
}
