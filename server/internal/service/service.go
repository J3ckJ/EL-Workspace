// Package service is the local Git host: repositories, pull requests,
// issues, CI, mirrors and backups.
package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/J3ckJ/EL-Workspace/server/internal/ci"
	"github.com/J3ckJ/EL-Workspace/server/internal/gitx"
	"github.com/J3ckJ/EL-Workspace/server/internal/names"
	"github.com/J3ckJ/EL-Workspace/server/internal/store"
	"golang.org/x/crypto/ssh"
)

// Error is a user-facing failure with an HTTP status.
type Error struct {
	Status int
	Msg    string
	Extra  any
}

func (e *Error) Error() string { return e.Msg }

func bad(status int, msg string) error { return &Error{Status: status, Msg: msg} }

// Service coordinates git and SQLite.
type Service struct {
	Data           string
	Store          *store.Store
	Git            gitx.Runner
	HTTPAddr       string
	SSHPort        int
	AdvertiseHost  string
	mirrorEvery    time.Duration
	ciJobs         chan ciJob
	locks          sync.Map
	ctx            context.Context
	cancel         context.CancelFunc
	lastBackupSlot string
	hooks          bool
}

type ciJob struct {
	repo  store.Repo
	ref   string
	sha   string
	event string
}

// New opens state under dataDir. The caller sets HTTPAddr and SSHPort once
// listeners are bound, then calls Start.
func New(dataDir string, st *store.Store, git gitx.Runner) *Service {
	ctx, cancel := context.WithCancel(context.Background())
	s := &Service{
		Data:        dataDir,
		Store:       st,
		Git:         git,
		mirrorEvery: 3 * time.Second,
		ciJobs:      make(chan ciJob, 64),
		ctx:         ctx,
		cancel:      cancel,
		hooks:       true,
	}
	if s.Store.Setting("owner", "") == "" {
		_ = s.Store.SetSetting("owner", "eugene")
	}
	if s.Store.Setting("display_name", "") == "" {
		_ = s.Store.SetSetting("display_name", "Евгений")
	}
	if s.Store.Setting("backup_time", "") == "" {
		_ = s.Store.SetSetting("backup_time", "03:00")
	}
	if s.Store.Setting("backup_dir", "") == "" {
		_ = s.Store.SetSetting("backup_dir", filepath.Join(dataDir, "backups"))
	}
	return s
}

// Start launches CI, mirror and backup workers.
func (s *Service) Start() {
	go s.ciLoop()
	go s.mirrorLoop()
	go s.backupLoop()
}

// Stop cancels background workers.
func (s *Service) Stop() { s.cancel() }

// SetMirrorEvery changes the mirror retry interval.
func (s *Service) SetMirrorEvery(d time.Duration) {
	if d > 0 {
		s.mirrorEvery = d
	}
}

func (s *Service) lock(id int64) func() {
	v, _ := s.locks.LoadOrStore(id, &sync.Mutex{})
	m := v.(*sync.Mutex)
	m.Lock()
	return m.Unlock
}

// Owner is the single local account.
func (s *Service) Owner() string {
	o := s.Store.Setting("owner", "eugene")
	if !names.Valid(o) {
		return "eugene"
	}
	return o
}

// DisplayName is the greeting name.
func (s *Service) DisplayName() string {
	n := s.Store.Setting("display_name", "Евгений")
	if strings.TrimSpace(n) == "" {
		return "Евгений"
	}
	return n
}

// RepoPath is the bare repository directory.
func (s *Service) RepoPath(owner, name string) (string, error) {
	if !names.Valid(owner) || !names.Valid(name) {
		return "", bad(http.StatusBadRequest, "Некорректное имя репозитория.")
	}
	return filepath.Join(s.Data, "repos", owner, name+".git"), nil
}

// Resolve returns the path of a known repository.
func (s *Service) Resolve(owner, name string) (string, error) {
	if _, err := s.Store.GetRepo(owner, name); err != nil {
		return "", err
	}
	return s.RepoPath(owner, name)
}

func (s *Service) repo(owner, name string) (store.Repo, string, error) {
	r, err := s.Store.GetRepo(owner, name)
	if err != nil {
		return store.Repo{}, "", bad(http.StatusNotFound, "Репозиторий не найден.")
	}
	path, err := s.RepoPath(owner, name)
	return r, path, err
}

// CreateRepo initializes a bare repository.
func (s *Service) CreateRepo(name, description, mode, mirror string, pinned bool) (store.Repo, error) {
	if !names.Valid(name) {
		return store.Repo{}, bad(http.StatusBadRequest, "Имя репозитория может содержать буквы, цифры, точку, _ и -.")
	}
	if mode == "" {
		mode = "local"
	}
	if !ValidMirrorMode(mode) {
		return store.Repo{}, bad(http.StatusBadRequest, "Неизвестный режим зеркала.")
	}
	owner := s.Owner()
	path, err := s.RepoPath(owner, name)
	if err != nil {
		return store.Repo{}, err
	}
	if err := s.Git.InitBare(path); err != nil {
		return store.Repo{}, bad(http.StatusInternalServerError, "Не удалось создать репозиторий: "+err.Error())
	}
	repo := store.Repo{
		Owner: owner, Name: name, Description: description,
		DefaultBranch: "main", MirrorURL: strings.TrimSpace(mirror), MirrorMode: mode, Pinned: pinned,
	}
	if err := s.Store.CreateRepo(&repo); err != nil {
		return store.Repo{}, bad(http.StatusConflict, "Репозиторий с таким именем уже есть.")
	}
	return repo, nil
}

// UpdateRepo changes description, pin and mirror settings.
func (s *Service) UpdateRepo(owner, name string, description *string, mode, mirror *string, pinned *bool) (store.Repo, error) {
	repo, _, err := s.repo(owner, name)
	if err != nil {
		return store.Repo{}, err
	}
	if description != nil {
		repo.Description = *description
	}
	if mode != nil {
		if !ValidMirrorMode(*mode) {
			return store.Repo{}, bad(http.StatusBadRequest, "Неизвестный режим зеркала.")
		}
		repo.MirrorMode = *mode
	}
	if mirror != nil {
		repo.MirrorURL = strings.TrimSpace(*mirror)
	}
	if pinned != nil {
		repo.Pinned = *pinned
	}
	if err := s.Store.UpdateRepo(repo); err != nil {
		return store.Repo{}, err
	}
	return repo, nil
}

// SetHooks enables ref side effects (CI, mirrors, auto-close).
func (s *Service) SetHooks(enabled bool) { s.hooks = enabled }

// WriteCommit creates a commit on a branch and runs ref side effects.
func (s *Service) WriteCommit(owner, name, branch, message string, when time.Time, files map[string]string) (string, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return "", err
	}
	if !validBranch(branch) {
		return "", bad(http.StatusBadRequest, "Некорректная ветка.")
	}
	unlock := s.lock(repo.ID)
	defer unlock()
	old, sha, err := s.Git.CommitFiles(path, branch, files, message, when)
	if err != nil {
		return "", err
	}
	s.HandleRefs(owner, name, []gitx.RefChange{{Ref: "refs/heads/" + branch, Old: old, New: sha}})
	return sha, nil
}

// HandleRefs reacts to a successful receive-pack or an internal ref move.
func (s *Service) HandleRefs(owner, name string, changes []gitx.RefChange) {
	if !s.hooks {
		return
	}
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return
	}
	for _, change := range changes {
		switch {
		case strings.HasPrefix(change.Ref, "refs/heads/"):
			branch := strings.TrimPrefix(change.Ref, "refs/heads/")
			if change.New == gitx.ZeroHash {
				continue
			}
			if branch == repo.DefaultBranch {
				s.closeFromRange(repo, path, change.Old, change.New, "")
				if repo.MirrorMode == "push" || repo.MirrorMode == "both" {
					_, _ = s.Store.EnqueueMirror(repo.ID, change.Ref, false)
				}
			} else if repo.MirrorMode == "both" {
				_, _ = s.Store.EnqueueMirror(repo.ID, change.Ref, false)
			}
			s.enqueueCI(repo, branch, change.New, "push")
		case strings.HasPrefix(change.Ref, "refs/tags/"):
			if change.New != gitx.ZeroHash && (repo.MirrorMode == "push" || repo.MirrorMode == "both") {
				_, _ = s.Store.EnqueueMirror(repo.ID, change.Ref, false)
			}
		}
	}
}

func (s *Service) closeFromRange(repo store.Repo, path, old, newSHA, extra string) {
	if newSHA == "" || newSHA == gitx.ZeroHash {
		return
	}
	var spec string
	if old == "" || old == gitx.ZeroHash {
		spec = newSHA
	} else {
		spec = old + ".." + newSHA
	}
	text, err := s.Git.Messages(path, spec)
	if err != nil {
		text = ""
	}
	text += "\n" + extra
	for _, n := range IssueNumbersClosedBy(text) {
		_, _ = s.Store.CloseIssueNumber(repo.ID, n)
	}
}

func (s *Service) enqueueCI(repo store.Repo, branch, sha, event string) {
	select {
	case s.ciJobs <- ciJob{repo: repo, ref: branch, sha: sha, event: event}:
	default:
	}
}

func (s *Service) ciLoop() {
	for {
		select {
		case <-s.ctx.Done():
			return
		case job := <-s.ciJobs:
			s.runWorkflows(job.repo, job.ref, job.sha, job.event)
		}
	}
}

// RunWorkflows executes matching workflows and returns the runs.
func (s *Service) RunWorkflows(owner, name, branch, event string) ([]store.CIRun, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	if branch == "" {
		branch = repo.DefaultBranch
	}
	sha, err := s.Git.RevParse(path, branch)
	if err != nil {
		return nil, bad(http.StatusBadRequest, "Ветка не найдена.")
	}
	return s.runWorkflows(repo, branch, sha, event), nil
}

func (s *Service) runWorkflows(repo store.Repo, branch, sha, event string) []store.CIRun {
	path, err := s.RepoPath(repo.Owner, repo.Name)
	if err != nil {
		return nil
	}
	entries, err := s.Git.Tree(path, sha, ".github/workflows")
	if err != nil {
		return nil
	}
	var runs []store.CIRun
	for _, entry := range entries {
		if entry.Type != "blob" {
			continue
		}
		if !strings.HasSuffix(entry.Name, ".yml") && !strings.HasSuffix(entry.Name, ".yaml") {
			continue
		}
		raw, binary, err := s.Git.Blob(path, sha, entry.Path)
		if err != nil || binary {
			continue
		}
		wf, err := ci.Parse(raw)
		if err != nil {
			continue
		}
		if event == "pull_request" && !wf.Pull {
			continue
		}
		if event == "push" && !wf.Push {
			if !wf.Pull {
				continue
			}
			if _, err := s.Store.OpenPullByHead(repo.ID, branch); err != nil {
				continue
			}
		}
		name := wf.Name
		if name == "" {
			name = entry.Name
		}
		run := store.CIRun{RepoID: repo.ID, Ref: branch, SHA: sha, Workflow: name, Status: "running", StartedAt: time.Now().UTC().Format(time.RFC3339)}
		if err := s.Store.CreateCIRun(&run); err != nil {
			continue
		}
		status, reason, jobs := s.execute(repo, path, branch, sha, wf, run.ID)
		rawJobs, _ := json.Marshal(jobs)
		run.Status = status
		run.Reason = reason
		run.Jobs = string(rawJobs)
		var logs []string
		for _, job := range jobs {
			logs = append(logs, job.Log)
		}
		run.Log = strings.Join(logs, "\n")
		if len(run.Log) > 200_000 {
			run.Log = run.Log[len(run.Log)-200_000:]
		}
		run.FinishedAt = time.Now().UTC().Format(time.RFC3339)
		_ = s.Store.UpdateCIRun(run)
		runs = append(runs, run)
	}
	return runs
}

func (s *Service) execute(repo store.Repo, repoPath, branch, sha string, wf ci.Workflow, runID int64) (string, string, []ci.JobResult) {
	parent, err := os.MkdirTemp("", "el-ci-")
	if err != nil {
		return "failure", err.Error(), nil
	}
	defer os.RemoveAll(parent)
	dest := filepath.Join(parent, "src")
	if _, err := s.Git.Run("", "clone", "--shared", repoPath, dest); err != nil {
		return "failure", "Не удалось подготовить рабочую копию.", nil
	}
	if _, err := s.Git.Run(dest, "checkout", "--detach", sha); err != nil {
		short := sha
		if len(short) > 7 {
			short = short[:7]
		}
		return "failure", "Не удалось переключить коммит " + short, nil
	}
	ref := "refs/heads/" + branch
	status, reason, jobs := ci.Run(dest, repo.Owner+"/"+repo.Name, ref, sha, wf, 2*time.Minute)
	_ = copyDir(filepath.Join(dest, "artifacts"), filepath.Join(s.Data, "ci", fmt.Sprintf("%d", runID)))
	return status, reason, jobs
}

func (s *Service) mirrorLoop() {
	ticker := time.NewTicker(s.mirrorEvery)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.DrainMirrors()
		}
	}
}

// DrainMirrors tries every queued mirror push once.
func (s *Service) DrainMirrors() {
	jobs, err := s.Store.DueMirrorJobs()
	if err != nil {
		return
	}
	for _, job := range jobs {
		repo, err := s.Store.GetRepoByID(job.RepoID)
		if err != nil {
			_ = s.Store.FinishMirrorJob(job.ID, "error", "репозиторий не найден")
			continue
		}
		if err := s.pushMirror(repo, job.Ref, job.Force); err != nil {
			_ = s.Store.FinishMirrorJob(job.ID, "error", err.Error())
			repo.MirrorStatus = "offline"
			repo.MirrorDetail = err.Error()
			_ = s.Store.UpdateRepo(repo)
			continue
		}
		_ = s.Store.FinishMirrorJob(job.ID, "done", "")
		repo.MirrorStatus = "synced"
		repo.MirrorDetail = ""
		_ = s.Store.UpdateRepo(repo)
	}
}

func (s *Service) pushMirror(repo store.Repo, ref string, force bool) error {
	if strings.TrimSpace(repo.MirrorURL) == "" || repo.MirrorMode == "local" {
		return fmt.Errorf("зеркало не настроено")
	}
	path, err := s.RepoPath(repo.Owner, repo.Name)
	if err != nil {
		return err
	}
	return s.Git.Push(path, repo.MirrorURL, ref, ref, force)
}

// LostCommits lists commits a force-push of ref would remove from the mirror.
type LostCommit struct {
	SHA     string `json:"sha"`
	Subject string `json:"subject"`
}

// PreviewForce lists commits that would be lost.
func (s *Service) PreviewForce(owner, name, ref string) ([]LostCommit, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	return s.lost(repo, path, ref)
}

func (s *Service) lost(repo store.Repo, path, ref string) ([]LostCommit, error) {
	if repo.MirrorURL == "" {
		return nil, bad(http.StatusBadRequest, "Зеркало не настроено.")
	}
	branch := strings.TrimPrefix(ref, "refs/heads/")
	branch = strings.TrimPrefix(branch, "refs/tags/")
	tracking := "refs/remotes/el-mirror/" + strings.ReplaceAll(branch, "/", "-")
	if err := s.Git.Fetch(path, repo.MirrorURL, ref+":"+tracking); err != nil {
		return nil, bad(http.StatusBadGateway, "Зеркало недоступно: "+err.Error())
	}
	local, err := s.Git.RevParse(path, ref)
	if err != nil {
		return nil, bad(http.StatusBadRequest, "Локальная ссылка не найдена.")
	}
	commits, err := s.Git.LostCommits(path, local, tracking)
	if err != nil {
		return nil, err
	}
	out := make([]LostCommit, 0, len(commits))
	for _, c := range commits {
		out = append(out, LostCommit{SHA: c.SHA, Subject: c.Subject})
	}
	return out, nil
}

// MirrorPush queues or performs a push. Force requires the exact lost set.
func (s *Service) MirrorPush(owner, name, ref string, force, confirm bool, acknowledged []string) error {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return err
	}
	if ref == "" {
		ref = "refs/heads/" + repo.DefaultBranch
	}
	if !strings.HasPrefix(ref, "refs/") {
		ref = "refs/heads/" + ref
	}
	if !force {
		_, err := s.Store.EnqueueMirror(repo.ID, ref, false)
		if err != nil {
			return err
		}
		if err := s.pushMirror(repo, ref, false); err != nil {
			return bad(http.StatusConflict, err.Error())
		}
		repo.MirrorStatus = "synced"
		repo.MirrorDetail = ""
		_ = s.Store.UpdateRepo(repo)
		return nil
	}
	lost, err := s.lost(repo, path, ref)
	if err != nil {
		return err
	}
	if len(lost) == 0 {
		return s.MirrorPush(owner, name, ref, false, false, nil)
	}
	if !confirm || !sameSHAs(acknowledged, lost) {
		return &Error{Status: http.StatusConflict, Msg: "Force-push удалит коммиты на зеркале. Подтвердите список.", Extra: map[string]any{"lost": lost}}
	}
	if err := s.pushMirror(repo, ref, true); err != nil {
		return bad(http.StatusBadGateway, err.Error())
	}
	repo.MirrorStatus = "synced"
	_ = s.Store.UpdateRepo(repo)
	return nil
}

func sameSHAs(got []string, lost []LostCommit) bool {
	if len(got) != len(lost) {
		return false
	}
	have := map[string]int{}
	for _, s := range got {
		have[s]++
	}
	for _, c := range lost {
		if have[c.SHA] == 0 {
			return false
		}
		have[c.SHA]--
	}
	return true
}

func (s *Service) backupLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.maybeBackup()
		}
	}
}

func (s *Service) maybeBackup() {
	at := s.Store.Setting("backup_time", "03:00")
	var last time.Time
	if b, err := s.Store.LatestBackup(); err == nil {
		last, _ = time.Parse(time.RFC3339, b.CreatedAt)
	}
	now := time.Now()
	if !DueBackup(now, at, last) {
		return
	}
	slot := now.Format("2006-01-02")
	if s.lastBackupSlot == slot {
		return
	}
	if _, err := s.BackupNow(); err == nil {
		s.lastBackupSlot = slot
	}
}

// BackupNow writes a git bundle for every repository that has commits.
func (s *Service) BackupNow() ([]store.Backup, error) {
	repos, err := s.Store.ListRepos()
	if err != nil {
		return nil, err
	}
	dir := s.Store.Setting("backup_dir", filepath.Join(s.Data, "backups"))
	var out []store.Backup
	for _, repo := range repos {
		path, err := s.RepoPath(repo.Owner, repo.Name)
		if err != nil || !s.Git.HasCommit(path) {
			continue
		}
		dest := filepath.Join(dir, repo.Owner, fmt.Sprintf("%s-%s.bundle", repo.Name, time.Now().UTC().Format("20060102-150405")))
		if err := s.Git.Bundle(path, dest); err != nil {
			return out, bad(http.StatusInternalServerError, repo.Name+": "+err.Error())
		}
		sum, err := fileSHA(dest)
		if err != nil {
			return out, err
		}
		b := store.Backup{RepoID: repo.ID, Path: dest, SHA256: sum}
		if err := s.Store.AddBackup(&b); err != nil {
			return out, err
		}
		out = append(out, b)
	}
	return out, nil
}

func fileSHA(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// AllowKey reports whether an SSH public key is registered.
func (s *Service) AllowKey(key ssh.PublicKey) bool {
	fp := ssh.FingerprintSHA256(key)
	keys, err := s.Store.ListKeys()
	if err != nil {
		return false
	}
	for _, item := range keys {
		if item.Fingerprint == fp {
			return true
		}
	}
	return false
}

// AddKey stores an authorized public key line.
func (s *Service) AddKey(title, line string) (store.SSHKey, error) {
	pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(strings.TrimSpace(line)))
	if err != nil {
		return store.SSHKey{}, bad(http.StatusBadRequest, "Не удалось прочитать открытый ключ.")
	}
	if strings.TrimSpace(title) == "" {
		title = "key"
	}
	k := store.SSHKey{Title: title, PublicKey: strings.TrimSpace(line), Fingerprint: ssh.FingerprintSHA256(pub)}
	if err := s.Store.AddKey(&k); err != nil {
		return store.SSHKey{}, bad(http.StatusConflict, "Такой ключ уже добавлен.")
	}
	return k, nil
}

// ImportDefaultKey adds the user's default public key when none are stored.
func (s *Service) ImportDefaultKey() {
	keys, err := s.Store.ListKeys()
	if err != nil || len(keys) > 0 {
		return
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	for _, name := range []string{"id_ed25519.pub", "id_rsa.pub"} {
		raw, err := os.ReadFile(filepath.Join(home, ".ssh", name))
		if err != nil {
			continue
		}
		_, _ = s.AddKey("эта машина", string(raw))
		return
	}
}

// PublicHTTP is the advertised smart HTTP origin.
func (s *Service) PublicHTTP() string {
	host := s.AdvertiseHost
	if host == "" {
		host = "127.0.0.1"
	}
	port := "8080"
	if i := strings.LastIndex(s.HTTPAddr, ":"); i >= 0 {
		port = s.HTTPAddr[i+1:]
		if s.AdvertiseHost == "" {
			bind := s.HTTPAddr[:i]
			if bind != "" && bind != "0.0.0.0" && bind != "::" {
				host = bind
			}
		}
	}
	return "http://" + host + ":" + port
}

// CloneURLs returns SSH and HTTP clone URLs.
func (s *Service) CloneURLs(owner, name string) (sshURL, httpURL string) {
	host := s.AdvertiseHost
	if host == "" {
		host = "127.0.0.1"
		if i := strings.LastIndex(s.HTTPAddr, ":"); i >= 0 {
			bind := s.HTTPAddr[:i]
			if bind != "" && bind != "0.0.0.0" && bind != "::" {
				host = bind
			}
		}
	}
	sshURL = fmt.Sprintf("ssh://git@%s:%d/%s/%s.git", host, s.SSHPort, owner, name)
	httpURL = fmt.Sprintf("%s/git/%s/%s.git", s.PublicHTTP(), owner, name)
	return sshURL, httpURL
}

func cleanRel(p string) (string, error) {
	p = strings.TrimSpace(p)
	p = strings.ReplaceAll(p, "\\", "/")
	if p == "." {
		p = ""
	}
	if strings.HasPrefix(p, "/") || strings.Contains(p, "..") {
		return "", bad(http.StatusBadRequest, "Некорректный путь.")
	}
	return p, nil
}

func validBranch(name string) bool {
	if name == "" || len(name) > 200 {
		return false
	}
	if strings.HasPrefix(name, "/") || strings.HasSuffix(name, "/") || strings.Contains(name, "..") {
		return false
	}
	if strings.ContainsAny(name, " ~^:?*[\\\x00") {
		return false
	}
	return true
}
