// Package api is the HTTP API and the embedded web UI.
package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/J3ckJ/EL-Workspace/server/internal/service"
	"github.com/J3ckJ/EL-Workspace/server/internal/store"
	"github.com/J3ckJ/EL-Workspace/server/internal/web"
)

// Server is the loopback HTTP application.
type Server struct {
	Svc     *service.Service
	HostKey string
}

// Handler is the full HTTP mux, including git smart HTTP mounted by the caller.
func (s *Server) Handler(git http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/git/", git)
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})
	mux.HandleFunc("GET /api/dashboard", s.dashboard)
	mux.HandleFunc("GET /api/sync", s.sync)
	mux.HandleFunc("GET /api/panel", s.panel)
	mux.HandleFunc("GET /api/search", s.search)
	mux.HandleFunc("GET /api/meta", s.meta)
	mux.HandleFunc("GET /api/settings", s.getSettings)
	mux.HandleFunc("PUT /api/settings", s.putSettings)
	mux.HandleFunc("GET /api/keys", s.listKeys)
	mux.HandleFunc("POST /api/keys", s.addKey)
	mux.HandleFunc("DELETE /api/keys/{id}", s.deleteKey)
	mux.HandleFunc("POST /api/backups", s.backup)
	mux.HandleFunc("GET /api/backups", s.listBackups)
	mux.HandleFunc("GET /api/repos", s.listRepos)
	mux.HandleFunc("POST /api/repos", s.createRepo)
	mux.HandleFunc("GET /api/repos/{owner}/{name}", s.getRepo)
	mux.HandleFunc("PATCH /api/repos/{owner}/{name}", s.patchRepo)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/tree", s.tree)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/blob", s.blob)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/readme", s.readme)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/commits", s.commits)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/commits/{sha}", s.commit)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/commits/{sha}/comments", s.commitComment)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/commits/{sha}/cherry-pick", s.cherry)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/diff", s.diff)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/refs", s.refs)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/issues", s.repoIssues)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/issues", s.createIssue)
	mux.HandleFunc("GET /api/issues", s.allIssues)
	mux.HandleFunc("PATCH /api/issues/{id}", s.patchIssue)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/pulls", s.listPulls)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/pulls", s.createPull)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/pulls/{n}", s.getPull)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/pulls/{n}/comments", s.pullComment)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/pulls/{n}/merge", s.mergePull)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/checkout/{n}", s.checkout)
	mux.HandleFunc("POST /api/comments/{id}/resolve", s.resolve)
	mux.HandleFunc("POST /api/comments/{id}/apply", s.apply)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/releases", s.listReleases)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/releases/preview", s.previewRelease)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/releases", s.createRelease)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/releases/{tag}/publish", s.publishRelease)
	mux.HandleFunc("GET /api/assets/{id}", s.asset)
	mux.HandleFunc("GET /api/ci", s.allCI)
	mux.HandleFunc("GET /api/ci/{id}", s.getCI)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/ci", s.repoCI)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/ci", s.runCI)
	mux.HandleFunc("POST /api/repos/{owner}/{name}/mirror/push", s.mirrorPush)
	mux.HandleFunc("GET /api/repos/{owner}/{name}/mirror/preview", s.mirrorPreview)
	mux.Handle("/", web.Handler())
	return mux
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Dashboard()
	respond(w, out, err)
}

func (s *Server) sync(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Link()
	respond(w, out, err)
}

func (s *Server) panel(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Panel()
	respond(w, out, err)
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Search(r.URL.Query().Get("q"))
	respond(w, out, err)
}

func (s *Server) meta(w http.ResponseWriter, r *http.Request) {
	counts, err := s.Svc.Store.Counts()
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"owner": s.Svc.Owner(), "name": s.Svc.DisplayName(),
		"http": s.Svc.PublicHTTP(), "sshPort": s.Svc.SSHPort, "counts": counts,
	})
}

func (s *Server) getSettings(w http.ResponseWriter, r *http.Request) {
	token := s.Svc.Store.Setting("github_token", "")
	writeJSON(w, http.StatusOK, map[string]any{
		"owner":          s.Svc.Owner(),
		"displayName":    s.Svc.DisplayName(),
		"backupDir":      s.Svc.Store.Setting("backup_dir", ""),
		"backupTime":     s.Svc.Store.Setting("backup_time", "03:00"),
		"advertiseHost":  s.Svc.AdvertiseHost,
		"githubTokenSet": token != "",
		"http":           s.Svc.PublicHTTP(),
		"sshPort":        s.Svc.SSHPort,
		"bind":           s.Svc.HTTPAddr,
	})
}

func (s *Server) putSettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		DisplayName   *string `json:"displayName"`
		BackupDir     *string `json:"backupDir"`
		BackupTime    *string `json:"backupTime"`
		AdvertiseHost *string `json:"advertiseHost"`
		GithubToken   *string `json:"githubToken"`
		ClearToken    bool    `json:"clearToken"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	if body.DisplayName != nil {
		_ = s.Svc.Store.SetSetting("display_name", strings.TrimSpace(*body.DisplayName))
	}
	if body.BackupDir != nil {
		_ = s.Svc.Store.SetSetting("backup_dir", strings.TrimSpace(*body.BackupDir))
	}
	if body.BackupTime != nil {
		_ = s.Svc.Store.SetSetting("backup_time", strings.TrimSpace(*body.BackupTime))
	}
	if body.AdvertiseHost != nil {
		s.Svc.AdvertiseHost = strings.TrimSpace(*body.AdvertiseHost)
		_ = s.Svc.Store.SetSetting("advertise_host", s.Svc.AdvertiseHost)
	}
	if body.ClearToken {
		_ = s.Svc.Store.SetSetting("github_token", "")
	} else if body.GithubToken != nil && strings.TrimSpace(*body.GithubToken) != "" {
		_ = s.Svc.Store.SetSetting("github_token", strings.TrimSpace(*body.GithubToken))
	}
	s.getSettings(w, r)
}

func (s *Server) listKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := s.Svc.Store.ListKeys()
	if err != nil {
		fail(w, err)
		return
	}
	if keys == nil {
		keys = []store.SSHKey{}
	}
	writeJSON(w, http.StatusOK, keys)
}

func (s *Server) addKey(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title string `json:"title"`
		Key   string `json:"key"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	key, err := s.Svc.AddKey(body.Title, body.Key)
	respond(w, key, err)
}

func (s *Server) deleteKey(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		fail(w, err)
		return
	}
	if err := s.Svc.Store.DeleteKey(id); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) backup(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.BackupNow()
	respond(w, out, err)
}

func (s *Server) listBackups(w http.ResponseWriter, r *http.Request) {
	items, err := s.Svc.Store.ListBackups(50)
	if err != nil {
		fail(w, err)
		return
	}
	if items == nil {
		items = []store.Backup{}
	}
	writeJSON(w, http.StatusOK, items)
}

func (s *Server) listRepos(w http.ResponseWriter, r *http.Request) {
	repos, err := s.Svc.Store.ListRepos()
	if err != nil {
		fail(w, err)
		return
	}
	if repos == nil {
		repos = []store.Repo{}
	}
	writeJSON(w, http.StatusOK, repos)
}

func (s *Server) createRepo(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		MirrorMode  string `json:"mirrorMode"`
		MirrorURL   string `json:"mirrorUrl"`
		Pinned      bool   `json:"pinned"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	repo, err := s.Svc.CreateRepo(body.Name, body.Description, body.MirrorMode, body.MirrorURL, body.Pinned)
	if err != nil {
		fail(w, err)
		return
	}
	sshURL, httpURL := s.Svc.CloneURLs(repo.Owner, repo.Name)
	writeJSON(w, http.StatusCreated, map[string]any{"repo": repo, "ssh": sshURL, "http": httpURL})
}

func (s *Server) getRepo(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Summary(r.PathValue("owner"), r.PathValue("name"))
	respond(w, out, err)
}

func (s *Server) patchRepo(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Description *string `json:"description"`
		MirrorMode  *string `json:"mirrorMode"`
		MirrorURL   *string `json:"mirrorUrl"`
		Pinned      *bool   `json:"pinned"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	repo, err := s.Svc.UpdateRepo(r.PathValue("owner"), r.PathValue("name"), body.Description, body.MirrorMode, body.MirrorURL, body.Pinned)
	respond(w, repo, err)
}

func (s *Server) tree(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Tree(r.PathValue("owner"), r.PathValue("name"), r.URL.Query().Get("ref"), r.URL.Query().Get("path"))
	respond(w, out, err)
}

func (s *Server) blob(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Blob(r.PathValue("owner"), r.PathValue("name"), r.URL.Query().Get("ref"), r.URL.Query().Get("path"))
	respond(w, out, err)
}

func (s *Server) readme(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Readme(r.PathValue("owner"), r.PathValue("name"), r.URL.Query().Get("ref"))
	respond(w, out, err)
}

func (s *Server) commits(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	out, err := s.Svc.Log(r.PathValue("owner"), r.PathValue("name"), r.URL.Query().Get("ref"), limit)
	respond(w, out, err)
}

func (s *Server) commit(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Commit(r.PathValue("owner"), r.PathValue("name"), r.PathValue("sha"), r.URL.Query().Get("w") == "1")
	respond(w, out, err)
}

func (s *Server) diff(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	out, err := s.Svc.Diff(r.PathValue("owner"), r.PathValue("name"), q.Get("sha"), q.Get("base"), q.Get("head"), q.Get("w") == "1")
	respond(w, out, err)
}

func (s *Server) refs(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.Refs(r.PathValue("owner"), r.PathValue("name"))
	respond(w, out, err)
}

func (s *Server) repoIssues(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.FilteredIssues(r.PathValue("owner"), r.PathValue("name"), r.URL.Query().Get("q"))
	respond(w, out, err)
}

func (s *Server) allIssues(w http.ResponseWriter, r *http.Request) {
	out, err := s.Svc.FilteredIssues("", "", r.URL.Query().Get("q"))
	respond(w, out, err)
}

func (s *Server) createIssue(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title  string   `json:"title"`
		Body   string   `json:"body"`
		Status string   `json:"status"`
		Labels []string `json:"labels"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	issue, err := s.Svc.CreateIssue(r.PathValue("owner"), r.PathValue("name"), body.Title, body.Body, body.Status, body.Labels)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, issue)
}

func (s *Server) patchIssue(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		fail(w, err)
		return
	}
	var body struct {
		Title  string   `json:"title"`
		Body   string   `json:"body"`
		Status string   `json:"status"`
		Labels []string `json:"labels"`
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		fail(w, err)
		return
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		fail(w, &service.Error{Status: http.StatusBadRequest, Msg: "Некорректный JSON."})
		return
	}
	setLabels := strings.Contains(string(raw), `"labels"`)
	issue, err := s.Svc.UpdateIssue(id, body.Title, body.Body, body.Status, body.Labels, setLabels)
	respond(w, issue, err)
}

func (s *Server) listPulls(w http.ResponseWriter, r *http.Request) {
	repo, err := s.Svc.Store.GetRepo(r.PathValue("owner"), r.PathValue("name"))
	if err != nil {
		fail(w, &service.Error{Status: http.StatusNotFound, Msg: "Репозиторий не найден."})
		return
	}
	pulls, err := s.Svc.Store.ListPulls(repo.ID)
	if err != nil {
		fail(w, err)
		return
	}
	if pulls == nil {
		pulls = []store.Pull{}
	}
	writeJSON(w, http.StatusOK, pulls)
}

func (s *Server) createPull(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title string `json:"title"`
		Body  string `json:"body"`
		Head  string `json:"head"`
		Base  string `json:"base"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	p, err := s.Svc.CreatePull(r.PathValue("owner"), r.PathValue("name"), body.Title, body.Body, body.Head, body.Base)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, p)
}

func (s *Server) getPull(w http.ResponseWriter, r *http.Request) {
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil {
		fail(w, &service.Error{Status: http.StatusBadRequest, Msg: "Некорректный номер."})
		return
	}
	out, err := s.Svc.PullView(r.PathValue("owner"), r.PathValue("name"), n)
	respond(w, out, err)
}

func (s *Server) pullComment(w http.ResponseWriter, r *http.Request) {
	n := r.PathValue("n")
	var body struct {
		Path   string `json:"path"`
		Line   int    `json:"line"`
		Body   string `json:"body"`
		Author string `json:"author"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	c, err := s.Svc.AddComment(r.PathValue("owner"), r.PathValue("name"), "pull:"+n, body.Path, body.Body, body.Author, body.Line)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, c)
}

func (s *Server) commitComment(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Path   string `json:"path"`
		Line   int    `json:"line"`
		Body   string `json:"body"`
		Author string `json:"author"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	c, err := s.Svc.AddComment(r.PathValue("owner"), r.PathValue("name"), "commit:"+r.PathValue("sha"), body.Path, body.Body, body.Author, body.Line)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, c)
}

func (s *Server) mergePull(w http.ResponseWriter, r *http.Request) {
	n, _ := strconv.Atoi(r.PathValue("n"))
	var body struct {
		Method string `json:"method"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	sha, err := s.Svc.MergePull(r.PathValue("owner"), r.PathValue("name"), n, body.Method)
	respond(w, map[string]any{"sha": sha}, err)
}

func (s *Server) checkout(w http.ResponseWriter, r *http.Request) {
	n, _ := strconv.Atoi(r.PathValue("n"))
	out, err := s.Svc.CheckoutInfo(r.PathValue("owner"), r.PathValue("name"), n)
	respond(w, out, err)
}

func (s *Server) resolve(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		fail(w, err)
		return
	}
	if err := s.Svc.Store.ResolveComment(id, true); err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) apply(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		fail(w, err)
		return
	}
	sha, err := s.Svc.ApplySuggestion(id)
	respond(w, map[string]any{"sha": sha}, err)
}

func (s *Server) cherry(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Branch string `json:"branch"`
	}
	_ = readJSON(r, &body)
	sha, err := s.Svc.CherryPick(r.PathValue("owner"), r.PathValue("name"), r.PathValue("sha"), body.Branch)
	respond(w, map[string]any{"sha": sha}, err)
}

func (s *Server) listReleases(w http.ResponseWriter, r *http.Request) {
	repo, err := s.Svc.Store.GetRepo(r.PathValue("owner"), r.PathValue("name"))
	if err != nil {
		fail(w, &service.Error{Status: http.StatusNotFound, Msg: "Репозиторий не найден."})
		return
	}
	items, err := s.Svc.Store.ListReleases(repo.ID)
	if err != nil {
		fail(w, err)
		return
	}
	if items == nil {
		items = []store.Release{}
	}
	writeJSON(w, http.StatusOK, items)
}

func (s *Server) previewRelease(w http.ResponseWriter, r *http.Request) {
	notes, err := s.Svc.ReleaseNotes(r.PathValue("owner"), r.PathValue("name"), r.URL.Query().Get("tag"))
	respond(w, map[string]any{"notes": notes}, err)
}

func (s *Server) createRelease(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Tag     string `json:"tag"`
		Title   string `json:"title"`
		Notes   string `json:"notes"`
		Publish bool   `json:"publish"`
		FromCI  bool   `json:"fromCi"`
		Assets  []struct {
			Name          string `json:"name"`
			ContentBase64 string `json:"contentBase64"`
		} `json:"assets"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	var assets []service.AssetIn
	for _, item := range body.Assets {
		raw, err := base64.StdEncoding.DecodeString(item.ContentBase64)
		if err != nil {
			fail(w, &service.Error{Status: http.StatusBadRequest, Msg: "Файл " + item.Name + " не декодируется."})
			return
		}
		assets = append(assets, service.AssetIn{Name: item.Name, Body: raw})
	}
	rel, err := s.Svc.CreateRelease(r.PathValue("owner"), r.PathValue("name"), body.Tag, body.Title, body.Notes, body.Publish, body.FromCI, assets)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, rel)
}

func (s *Server) publishRelease(w http.ResponseWriter, r *http.Request) {
	err := s.Svc.PublishRelease(r.PathValue("owner"), r.PathValue("name"), r.PathValue("tag"))
	respond(w, map[string]any{"ok": err == nil}, err)
}

func (s *Server) asset(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		fail(w, err)
		return
	}
	asset, err := s.Svc.Store.GetAsset(id)
	if err != nil {
		fail(w, &service.Error{Status: http.StatusNotFound, Msg: "Файл не найден."})
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Checksum-Sha256", asset.SHA256)
	w.Header().Set("Content-Disposition", "attachment; filename=\""+asset.Name+"\"")
	http.ServeFile(w, r, asset.StoredPath)
}

func (s *Server) allCI(w http.ResponseWriter, r *http.Request) {
	s.writeCI(w, 0)
}

func (s *Server) repoCI(w http.ResponseWriter, r *http.Request) {
	repo, err := s.Svc.Store.GetRepo(r.PathValue("owner"), r.PathValue("name"))
	if err != nil {
		fail(w, &service.Error{Status: http.StatusNotFound, Msg: "Репозиторий не найден."})
		return
	}
	s.writeCI(w, repo.ID)
}

func (s *Server) writeCI(w http.ResponseWriter, repoID int64) {
	runs, err := s.Svc.Store.ListCIRuns(repoID, 40)
	if err != nil {
		fail(w, err)
		return
	}
	if runs == nil {
		runs = []store.CIRun{}
	}
	repos, _ := s.Svc.Store.ListRepos()
	names := map[int64]string{}
	for _, repo := range repos {
		names[repo.ID] = repo.Owner + "/" + repo.Name
	}
	out := make([]map[string]any, 0, len(runs))
	for _, run := range runs {
		out = append(out, map[string]any{
			"id": run.ID, "repoId": run.RepoID, "repo": names[run.RepoID], "ref": run.Ref,
			"sha": run.SHA, "workflow": run.Workflow, "status": run.Status, "jobs": json.RawMessage(emptyJSON(run.Jobs)),
			"log": run.Log, "reason": run.Reason, "startedAt": run.StartedAt, "finishedAt": run.FinishedAt,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) getCI(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		fail(w, err)
		return
	}
	run, err := s.Svc.Store.GetCIRun(id)
	if err != nil {
		fail(w, &service.Error{Status: http.StatusNotFound, Msg: "Сборка не найдена."})
		return
	}
	writeJSON(w, http.StatusOK, run)
}

func (s *Server) runCI(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Ref   string `json:"ref"`
		Event string `json:"event"`
	}
	_ = readJSON(r, &body)
	if body.Event == "" {
		body.Event = "push"
	}
	runs, err := s.Svc.RunWorkflows(r.PathValue("owner"), r.PathValue("name"), body.Ref, body.Event)
	respond(w, runs, err)
}

func (s *Server) mirrorPush(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Ref     string   `json:"ref"`
		Force   bool     `json:"force"`
		Confirm bool     `json:"confirm"`
		Lost    []string `json:"lost"`
	}
	if err := readJSON(r, &body); err != nil {
		fail(w, err)
		return
	}
	err := s.Svc.MirrorPush(r.PathValue("owner"), r.PathValue("name"), body.Ref, body.Force, body.Confirm, body.Lost)
	respond(w, map[string]any{"ok": err == nil}, err)
}

func (s *Server) mirrorPreview(w http.ResponseWriter, r *http.Request) {
	ref := r.URL.Query().Get("ref")
	lost, err := s.Svc.PreviewForce(r.PathValue("owner"), r.PathValue("name"), ref)
	respond(w, map[string]any{"lost": lost}, err)
}

func emptyJSON(s string) string {
	if strings.TrimSpace(s) == "" {
		return "[]"
	}
	return s
}

func pathID(r *http.Request, key string) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue(key), 10, 64)
	if err != nil {
		return 0, &service.Error{Status: http.StatusBadRequest, Msg: "Некорректный идентификатор."}
	}
	return id, nil
}

func readJSON(r *http.Request, dest any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 8<<20))
	if err := dec.Decode(dest); err != nil {
		return &service.Error{Status: http.StatusBadRequest, Msg: "Некорректный JSON."}
	}
	return nil
}

func respond(w http.ResponseWriter, body any, err error) {
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, body)
}

func fail(w http.ResponseWriter, err error) {
	var se *service.Error
	if errors.As(err, &se) {
		payload := map[string]any{"error": se.Msg}
		if se.Extra != nil {
			if extra, ok := se.Extra.(map[string]any); ok {
				for k, v := range extra {
					payload[k] = v
				}
			}
		}
		writeJSON(w, se.Status, payload)
		return
	}
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "Не найдено."})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(body)
}
