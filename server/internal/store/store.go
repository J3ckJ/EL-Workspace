// Package store is the SQLite state for issues, pull requests, CI, mirrors
// and settings. Git objects themselves live in bare repositories on disk.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// ErrNotFound is returned when a row does not exist.
var ErrNotFound = errors.New("not found")

// Store is a process-local SQLite database.
type Store struct {
	db *sql.DB
	mu sync.Mutex
}

// Open creates the schema if needed.
func Open(path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=busy_timeout(10000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

// Close releases the database.
func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	_, err := s.db.Exec(schema)
	return err
}

const schema = `
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS repos (
  id INTEGER PRIMARY KEY,
  owner TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  default_branch TEXT NOT NULL DEFAULT 'main',
  mirror_url TEXT NOT NULL DEFAULT '',
  mirror_mode TEXT NOT NULL DEFAULT 'local',
  pinned INTEGER NOT NULL DEFAULT 0,
  mirror_status TEXT NOT NULL DEFAULT '',
  mirror_detail TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  UNIQUE(owner, name)
);
CREATE TABLE IF NOT EXISTS issues (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL,
  number INTEGER NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  labels TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(repo_id, number)
);
CREATE TABLE IF NOT EXISTS pulls (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL,
  number INTEGER NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  head TEXT NOT NULL,
  base TEXT NOT NULL,
  status TEXT NOT NULL,
  merge_sha TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(repo_id, number)
);
CREATE TABLE IF NOT EXISTS comments (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL,
  target TEXT NOT NULL,
  path TEXT NOT NULL DEFAULT '',
  line INTEGER NOT NULL DEFAULT 0,
  body TEXT NOT NULL,
  suggestion TEXT NOT NULL DEFAULT '',
  author TEXT NOT NULL,
  resolved INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS releases (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL,
  tag TEXT NOT NULL,
  title TEXT NOT NULL,
  notes TEXT NOT NULL,
  published INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  UNIQUE(repo_id, tag)
);
CREATE TABLE IF NOT EXISTS assets (
  id INTEGER PRIMARY KEY,
  release_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  stored_path TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  size INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ci_runs (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL,
  ref TEXT NOT NULL,
  sha TEXT NOT NULL,
  workflow TEXT NOT NULL,
  status TEXT NOT NULL,
  jobs TEXT NOT NULL DEFAULT '[]',
  log TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL DEFAULT '',
  started_at TEXT NOT NULL DEFAULT '',
  finished_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS ssh_keys (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  public_key TEXT NOT NULL,
  fingerprint TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS mirror_jobs (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL,
  ref TEXT NOT NULL,
  force INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  error TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS backups (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  created_at TEXT NOT NULL
);
`

func now() string { return time.Now().UTC().Format(time.RFC3339) }

// Setting reads a string setting.
func (s *Store) Setting(key, def string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var v string
	err := s.db.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&v)
	if err != nil {
		return def
	}
	return v
}

// SetSetting upserts a setting.
func (s *Store) SetSetting(key, value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`INSERT INTO settings(key, value) VALUES(?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

// Repo is a hosted repository record.
type Repo struct {
	ID            int64  `json:"id"`
	Owner         string `json:"owner"`
	Name          string `json:"name"`
	Description   string `json:"description"`
	DefaultBranch string `json:"defaultBranch"`
	MirrorURL     string `json:"mirrorUrl"`
	MirrorMode    string `json:"mirrorMode"`
	Pinned        bool   `json:"pinned"`
	MirrorStatus  string `json:"mirrorStatus"`
	MirrorDetail  string `json:"mirrorDetail"`
	CreatedAt     string `json:"createdAt"`
}

func scanRepo(sc interface{ Scan(...any) error }) (Repo, error) {
	var r Repo
	var pinned int
	err := sc.Scan(&r.ID, &r.Owner, &r.Name, &r.Description, &r.DefaultBranch,
		&r.MirrorURL, &r.MirrorMode, &pinned, &r.MirrorStatus, &r.MirrorDetail, &r.CreatedAt)
	r.Pinned = pinned == 1
	return r, err
}

const repoCols = `id, owner, name, description, default_branch, mirror_url, mirror_mode, pinned, mirror_status, mirror_detail, created_at`

// CreateRepo inserts a repository row.
func (s *Store) CreateRepo(r *Repo) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.CreatedAt == "" {
		r.CreatedAt = now()
	}
	if r.DefaultBranch == "" {
		r.DefaultBranch = "main"
	}
	if r.MirrorMode == "" {
		r.MirrorMode = "local"
	}
	pin := 0
	if r.Pinned {
		pin = 1
	}
	res, err := s.db.Exec(`INSERT INTO repos(owner, name, description, default_branch, mirror_url, mirror_mode, pinned, mirror_status, mirror_detail, created_at)
		VALUES(?,?,?,?,?,?,?,?,?,?)`,
		r.Owner, r.Name, r.Description, r.DefaultBranch, r.MirrorURL, r.MirrorMode, pin, r.MirrorStatus, r.MirrorDetail, r.CreatedAt)
	if err != nil {
		return err
	}
	r.ID, _ = res.LastInsertId()
	return nil
}

// UpdateRepo saves mutable repository fields.
func (s *Store) UpdateRepo(r Repo) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	pin := 0
	if r.Pinned {
		pin = 1
	}
	res, err := s.db.Exec(`UPDATE repos SET description=?, default_branch=?, mirror_url=?, mirror_mode=?, pinned=?, mirror_status=?, mirror_detail=? WHERE id=?`,
		r.Description, r.DefaultBranch, r.MirrorURL, r.MirrorMode, pin, r.MirrorStatus, r.MirrorDetail, r.ID)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// GetRepo returns one repository.
func (s *Store) GetRepo(owner, name string) (Repo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, err := scanRepo(s.db.QueryRow(`SELECT `+repoCols+` FROM repos WHERE owner=? AND name=?`, owner, name))
	if errors.Is(err, sql.ErrNoRows) {
		return Repo{}, ErrNotFound
	}
	return r, err
}

// GetRepoByID returns one repository.
func (s *Store) GetRepoByID(id int64) (Repo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, err := scanRepo(s.db.QueryRow(`SELECT `+repoCols+` FROM repos WHERE id=?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Repo{}, ErrNotFound
	}
	return r, err
}

// ListRepos returns every repository, pinned first.
func (s *Store) ListRepos() ([]Repo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT ` + repoCols + ` FROM repos ORDER BY pinned DESC, name COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Repo
	for rows.Next() {
		r, err := scanRepo(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Issue is a kanban card.
type Issue struct {
	ID        int64    `json:"id"`
	RepoID    int64    `json:"repoId"`
	Number    int      `json:"number"`
	Title     string   `json:"title"`
	Body      string   `json:"body"`
	Status    string   `json:"status"`
	Labels    []string `json:"labels"`
	CreatedAt string   `json:"createdAt"`
	UpdatedAt string   `json:"updatedAt"`
}

func (s *Store) nextNumber(table string, repoID int64) (int, error) {
	var n sql.NullInt64
	err := s.db.QueryRow(`SELECT MAX(number) FROM `+table+` WHERE repo_id=?`, repoID).Scan(&n)
	if err != nil {
		return 0, err
	}
	return int(n.Int64) + 1, nil
}

// CreateIssue inserts an issue and assigns the next per-repo number.
func (s *Store) CreateIssue(issue *Issue) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.nextNumber("issues", issue.RepoID)
	if err != nil {
		return err
	}
	issue.Number = n
	if issue.Status == "" {
		issue.Status = "backlog"
	}
	issue.CreatedAt = now()
	issue.UpdatedAt = issue.CreatedAt
	labels := encodeLabels(issue.Labels)
	res, err := s.db.Exec(`INSERT INTO issues(repo_id, number, title, body, status, labels, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?)`,
		issue.RepoID, issue.Number, issue.Title, issue.Body, issue.Status, labels, issue.CreatedAt, issue.UpdatedAt)
	if err != nil {
		return err
	}
	issue.ID, _ = res.LastInsertId()
	return nil
}

// UpdateIssue updates status, title and labels.
func (s *Store) UpdateIssue(issue Issue) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`UPDATE issues SET title=?, body=?, status=?, labels=?, updated_at=? WHERE id=?`,
		issue.Title, issue.Body, issue.Status, encodeLabels(issue.Labels), now(), issue.ID)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// CloseIssueNumber moves an open issue to done.
func (s *Store) CloseIssueNumber(repoID int64, number int) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`UPDATE issues SET status='done', updated_at=? WHERE repo_id=? AND number=? AND status!='done'`,
		now(), repoID, number)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ListIssues returns issues, optionally for one repository.
func (s *Store) ListIssues(repoID int64) ([]Issue, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	q := `SELECT id, repo_id, number, title, body, status, labels, created_at, updated_at FROM issues`
	var rows *sql.Rows
	var err error
	if repoID == 0 {
		rows, err = s.db.Query(q + ` ORDER BY updated_at DESC`)
	} else {
		rows, err = s.db.Query(q+` WHERE repo_id=? ORDER BY number DESC`, repoID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanIssues(rows)
}

// GetIssue returns one issue.
func (s *Store) GetIssue(id int64) (Issue, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	row := s.db.QueryRow(`SELECT id, repo_id, number, title, body, status, labels, created_at, updated_at FROM issues WHERE id=?`, id)
	items, err := scanIssueRow(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Issue{}, ErrNotFound
	}
	return items, err
}

// Pull is a pull request.
type Pull struct {
	ID        int64  `json:"id"`
	RepoID    int64  `json:"repoId"`
	Number    int    `json:"number"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Head      string `json:"head"`
	Base      string `json:"base"`
	Status    string `json:"status"`
	MergeSHA  string `json:"mergeSha"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

// CreatePull inserts a pull request.
func (s *Store) CreatePull(p *Pull) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.nextNumber("pulls", p.RepoID)
	if err != nil {
		return err
	}
	p.Number = n
	p.Status = "open"
	p.CreatedAt = now()
	p.UpdatedAt = p.CreatedAt
	res, err := s.db.Exec(`INSERT INTO pulls(repo_id, number, title, body, head, base, status, merge_sha, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
		p.RepoID, p.Number, p.Title, p.Body, p.Head, p.Base, p.Status, "", p.CreatedAt, p.UpdatedAt)
	if err != nil {
		return err
	}
	p.ID, _ = res.LastInsertId()
	return nil
}

// GetPull returns a pull request by number.
func (s *Store) GetPull(repoID int64, number int) (Pull, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.getPull(repoID, number)
}

func (s *Store) getPull(repoID int64, number int) (Pull, error) {
	var p Pull
	err := s.db.QueryRow(`SELECT id, repo_id, number, title, body, head, base, status, merge_sha, created_at, updated_at FROM pulls WHERE repo_id=? AND number=?`,
		repoID, number).Scan(&p.ID, &p.RepoID, &p.Number, &p.Title, &p.Body, &p.Head, &p.Base, &p.Status, &p.MergeSHA, &p.CreatedAt, &p.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Pull{}, ErrNotFound
	}
	return p, err
}

// ListPulls returns pull requests for a repository. repoID 0 lists all.
func (s *Store) ListPulls(repoID int64) ([]Pull, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	q := `SELECT id, repo_id, number, title, body, head, base, status, merge_sha, created_at, updated_at FROM pulls`
	var rows *sql.Rows
	var err error
	if repoID == 0 {
		rows, err = s.db.Query(q + ` ORDER BY updated_at DESC`)
	} else {
		rows, err = s.db.Query(q+` WHERE repo_id=? ORDER BY number DESC`, repoID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Pull
	for rows.Next() {
		var p Pull
		if err := rows.Scan(&p.ID, &p.RepoID, &p.Number, &p.Title, &p.Body, &p.Head, &p.Base, &p.Status, &p.MergeSHA, &p.CreatedAt, &p.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// FinishPull marks a pull request merged or closed.
func (s *Store) FinishPull(repoID int64, number int, status, mergeSHA string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`UPDATE pulls SET status=?, merge_sha=?, updated_at=? WHERE repo_id=? AND number=?`,
		status, mergeSHA, now(), repoID, number)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// OpenPullByHead finds an open pull request for a branch.
func (s *Store) OpenPullByHead(repoID int64, head string) (Pull, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var p Pull
	err := s.db.QueryRow(`SELECT id, repo_id, number, title, body, head, base, status, merge_sha, created_at, updated_at FROM pulls WHERE repo_id=? AND head=? AND status='open' ORDER BY number DESC LIMIT 1`,
		repoID, head).Scan(&p.ID, &p.RepoID, &p.Number, &p.Title, &p.Body, &p.Head, &p.Base, &p.Status, &p.MergeSHA, &p.CreatedAt, &p.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Pull{}, ErrNotFound
	}
	return p, err
}

// Comment is an inline note on a pull request or a commit.
type Comment struct {
	ID         int64  `json:"id"`
	RepoID     int64  `json:"repoId"`
	Target     string `json:"target"`
	Path       string `json:"path"`
	Line       int    `json:"line"`
	Body       string `json:"body"`
	Suggestion string `json:"suggestion"`
	Author     string `json:"author"`
	Resolved   bool   `json:"resolved"`
	CreatedAt  string `json:"createdAt"`
}

// CreateComment inserts a comment.
func (s *Store) CreateComment(c *Comment) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c.CreatedAt = now()
	res, err := s.db.Exec(`INSERT INTO comments(repo_id, target, path, line, body, suggestion, author, resolved, created_at) VALUES(?,?,?,?,?,?,?,?,?)`,
		c.RepoID, c.Target, c.Path, c.Line, c.Body, c.Suggestion, c.Author, 0, c.CreatedAt)
	if err != nil {
		return err
	}
	c.ID, _ = res.LastInsertId()
	return nil
}

// ListComments returns comments for a target such as "pull:2".
func (s *Store) ListComments(repoID int64, target string) ([]Comment, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT id, repo_id, target, path, line, body, suggestion, author, resolved, created_at FROM comments WHERE repo_id=? AND target=? ORDER BY id`, repoID, target)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Comment
	for rows.Next() {
		c, err := scanComment(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// GetComment returns one comment.
func (s *Store) GetComment(id int64) (Comment, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	row := s.db.QueryRow(`SELECT id, repo_id, target, path, line, body, suggestion, author, resolved, created_at FROM comments WHERE id=?`, id)
	c, err := scanComment(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Comment{}, ErrNotFound
	}
	return c, err
}

// ResolveComment marks a comment resolved.
func (s *Store) ResolveComment(id int64, resolved bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := 0
	if resolved {
		v = 1
	}
	res, err := s.db.Exec(`UPDATE comments SET resolved=? WHERE id=?`, v, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func scanComment(sc interface{ Scan(...any) error }) (Comment, error) {
	var c Comment
	var resolved int
	err := sc.Scan(&c.ID, &c.RepoID, &c.Target, &c.Path, &c.Line, &c.Body, &c.Suggestion, &c.Author, &resolved, &c.CreatedAt)
	c.Resolved = resolved == 1
	return c, err
}

// Release is a tagged release.
type Release struct {
	ID        int64   `json:"id"`
	RepoID    int64   `json:"repoId"`
	Tag       string  `json:"tag"`
	Title     string  `json:"title"`
	Notes     string  `json:"notes"`
	Published bool    `json:"published"`
	CreatedAt string  `json:"createdAt"`
	Assets    []Asset `json:"assets,omitempty"`
}

// Asset is a file attached to a release.
type Asset struct {
	ID         int64  `json:"id"`
	ReleaseID  int64  `json:"releaseId"`
	Name       string `json:"name"`
	StoredPath string `json:"-"`
	SHA256     string `json:"sha256"`
	Size       int64  `json:"size"`
}

// CreateRelease inserts a release.
func (s *Store) CreateRelease(rel *Release) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	rel.CreatedAt = now()
	pub := 0
	if rel.Published {
		pub = 1
	}
	res, err := s.db.Exec(`INSERT INTO releases(repo_id, tag, title, notes, published, created_at) VALUES(?,?,?,?,?,?)`,
		rel.RepoID, rel.Tag, rel.Title, rel.Notes, pub, rel.CreatedAt)
	if err != nil {
		return err
	}
	rel.ID, _ = res.LastInsertId()
	return nil
}

// ListReleases returns releases for one repo, or all when repoID is 0.
func (s *Store) ListReleases(repoID int64) ([]Release, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	q := `SELECT id, repo_id, tag, title, notes, published, created_at FROM releases`
	var rows *sql.Rows
	var err error
	if repoID == 0 {
		rows, err = s.db.Query(q + ` ORDER BY created_at DESC`)
	} else {
		rows, err = s.db.Query(q+` WHERE repo_id=? ORDER BY created_at DESC`, repoID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Release
	for rows.Next() {
		rel, err := scanRelease(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, rel)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range out {
		assets, err := s.assetsLocked(out[i].ID)
		if err != nil {
			return nil, err
		}
		out[i].Assets = assets
	}
	return out, nil
}

// GetReleaseByTag returns a release.
func (s *Store) GetReleaseByTag(repoID int64, tag string) (Release, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	row := s.db.QueryRow(`SELECT id, repo_id, tag, title, notes, published, created_at FROM releases WHERE repo_id=? AND tag=?`, repoID, tag)
	rel, err := scanRelease(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Release{}, ErrNotFound
	}
	if err != nil {
		return Release{}, err
	}
	rel.Assets, err = s.assetsLocked(rel.ID)
	return rel, err
}

// MarkReleasePublished sets the published flag.
func (s *Store) MarkReleasePublished(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE releases SET published=1 WHERE id=?`, id)
	return err
}

// AddAsset attaches a file to a release.
func (s *Store) AddAsset(a *Asset) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`INSERT INTO assets(release_id, name, stored_path, sha256, size) VALUES(?,?,?,?,?)`,
		a.ReleaseID, a.Name, a.StoredPath, a.SHA256, a.Size)
	if err != nil {
		return err
	}
	a.ID, _ = res.LastInsertId()
	return nil
}

// GetAsset returns one asset.
func (s *Store) GetAsset(id int64) (Asset, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var a Asset
	err := s.db.QueryRow(`SELECT id, release_id, name, stored_path, sha256, size FROM assets WHERE id=?`, id).
		Scan(&a.ID, &a.ReleaseID, &a.Name, &a.StoredPath, &a.SHA256, &a.Size)
	if errors.Is(err, sql.ErrNoRows) {
		return Asset{}, ErrNotFound
	}
	return a, err
}

func (s *Store) assetsLocked(releaseID int64) ([]Asset, error) {
	rows, err := s.db.Query(`SELECT id, release_id, name, stored_path, sha256, size FROM assets WHERE release_id=? ORDER BY name`, releaseID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Asset
	for rows.Next() {
		var a Asset
		if err := rows.Scan(&a.ID, &a.ReleaseID, &a.Name, &a.StoredPath, &a.SHA256, &a.Size); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func scanRelease(sc interface{ Scan(...any) error }) (Release, error) {
	var rel Release
	var pub int
	err := sc.Scan(&rel.ID, &rel.RepoID, &rel.Tag, &rel.Title, &rel.Notes, &pub, &rel.CreatedAt)
	rel.Published = pub == 1
	return rel, err
}

// CIRun is one workflow execution.
type CIRun struct {
	ID         int64  `json:"id"`
	RepoID     int64  `json:"repoId"`
	Ref        string `json:"ref"`
	SHA        string `json:"sha"`
	Workflow   string `json:"workflow"`
	Status     string `json:"status"`
	Jobs       string `json:"jobs"`
	Log        string `json:"log"`
	Reason     string `json:"reason"`
	StartedAt  string `json:"startedAt"`
	FinishedAt string `json:"finishedAt"`
}

// CreateCIRun inserts a queued run.
func (s *Store) CreateCIRun(run *CIRun) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if run.Status == "" {
		run.Status = "queued"
	}
	if run.Jobs == "" {
		run.Jobs = "[]"
	}
	res, err := s.db.Exec(`INSERT INTO ci_runs(repo_id, ref, sha, workflow, status, jobs, log, reason, started_at, finished_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
		run.RepoID, run.Ref, run.SHA, run.Workflow, run.Status, run.Jobs, run.Log, run.Reason, run.StartedAt, run.FinishedAt)
	if err != nil {
		return err
	}
	run.ID, _ = res.LastInsertId()
	return nil
}

// UpdateCIRun saves status, log and jobs.
func (s *Store) UpdateCIRun(run CIRun) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE ci_runs SET status=?, jobs=?, log=?, reason=?, started_at=?, finished_at=? WHERE id=?`,
		run.Status, run.Jobs, run.Log, run.Reason, run.StartedAt, run.FinishedAt, run.ID)
	return err
}

// GetCIRun returns one run.
func (s *Store) GetCIRun(id int64) (CIRun, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.scanRun(s.db.QueryRow(`SELECT id, repo_id, ref, sha, workflow, status, jobs, log, reason, started_at, finished_at FROM ci_runs WHERE id=?`, id))
}

// ListCIRuns returns recent runs.
func (s *Store) ListCIRuns(repoID int64, limit int) ([]CIRun, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if limit <= 0 {
		limit = 50
	}
	q := `SELECT id, repo_id, ref, sha, workflow, status, jobs, log, reason, started_at, finished_at FROM ci_runs`
	var rows *sql.Rows
	var err error
	if repoID == 0 {
		rows, err = s.db.Query(q+` ORDER BY id DESC LIMIT ?`, limit)
	} else {
		rows, err = s.db.Query(q+` WHERE repo_id=? ORDER BY id DESC LIMIT ?`, repoID, limit)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CIRun
	for rows.Next() {
		run, err := s.scanRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, run)
	}
	return out, rows.Err()
}

func (s *Store) scanRun(sc interface{ Scan(...any) error }) (CIRun, error) {
	var r CIRun
	err := sc.Scan(&r.ID, &r.RepoID, &r.Ref, &r.SHA, &r.Workflow, &r.Status, &r.Jobs, &r.Log, &r.Reason, &r.StartedAt, &r.FinishedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return CIRun{}, ErrNotFound
	}
	return r, err
}

// SSHKey is an authorized public key.
type SSHKey struct {
	ID          int64  `json:"id"`
	Title       string `json:"title"`
	PublicKey   string `json:"publicKey"`
	Fingerprint string `json:"fingerprint"`
	CreatedAt   string `json:"createdAt"`
}

// AddKey inserts a public key.
func (s *Store) AddKey(k *SSHKey) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	k.CreatedAt = now()
	res, err := s.db.Exec(`INSERT INTO ssh_keys(title, public_key, fingerprint, created_at) VALUES(?,?,?,?)`,
		k.Title, k.PublicKey, k.Fingerprint, k.CreatedAt)
	if err != nil {
		return err
	}
	k.ID, _ = res.LastInsertId()
	return nil
}

// ListKeys returns authorized keys.
func (s *Store) ListKeys() ([]SSHKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT id, title, public_key, fingerprint, created_at FROM ssh_keys ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SSHKey
	for rows.Next() {
		var k SSHKey
		if err := rows.Scan(&k.ID, &k.Title, &k.PublicKey, &k.Fingerprint, &k.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// DeleteKey removes a key.
func (s *Store) DeleteKey(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`DELETE FROM ssh_keys WHERE id=?`, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// MirrorJob is a queued push to a mirror remote.
type MirrorJob struct {
	ID        int64  `json:"id"`
	RepoID    int64  `json:"repoId"`
	Ref       string `json:"ref"`
	Force     bool   `json:"force"`
	Status    string `json:"status"`
	Error     string `json:"error"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

// EnqueueMirror records a mirror push. Duplicate queued refs are reused.
func (s *Store) EnqueueMirror(repoID int64, ref string, force bool) (MirrorJob, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var existing MirrorJob
	var forceInt int
	err := s.db.QueryRow(`SELECT id, repo_id, ref, force, status, error, created_at, updated_at FROM mirror_jobs WHERE repo_id=? AND ref=? AND status IN ('queued','error') ORDER BY id DESC LIMIT 1`,
		repoID, ref).Scan(&existing.ID, &existing.RepoID, &existing.Ref, &forceInt, &existing.Status, &existing.Error, &existing.CreatedAt, &existing.UpdatedAt)
	if err == nil {
		existing.Force = forceInt == 1 || force
		_, _ = s.db.Exec(`UPDATE mirror_jobs SET status='queued', force=?, updated_at=? WHERE id=?`, boolInt(existing.Force), now(), existing.ID)
		existing.Status = "queued"
		return existing, nil
	}
	job := MirrorJob{RepoID: repoID, Ref: ref, Force: force, Status: "queued", CreatedAt: now(), UpdatedAt: now()}
	res, err := s.db.Exec(`INSERT INTO mirror_jobs(repo_id, ref, force, status, error, created_at, updated_at) VALUES(?,?,?,?,?,?,?)`,
		job.RepoID, job.Ref, boolInt(job.Force), job.Status, "", job.CreatedAt, job.UpdatedAt)
	if err != nil {
		return MirrorJob{}, err
	}
	job.ID, _ = res.LastInsertId()
	return job, nil
}

// DueMirrorJobs returns jobs the worker should try.
func (s *Store) DueMirrorJobs() ([]MirrorJob, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT id, repo_id, ref, force, status, error, created_at, updated_at FROM mirror_jobs WHERE status IN ('queued','error') ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []MirrorJob
	for rows.Next() {
		var j MirrorJob
		var force int
		if err := rows.Scan(&j.ID, &j.RepoID, &j.Ref, &force, &j.Status, &j.Error, &j.CreatedAt, &j.UpdatedAt); err != nil {
			return nil, err
		}
		j.Force = force == 1
		out = append(out, j)
	}
	return out, rows.Err()
}

// FinishMirrorJob updates a job after an attempt.
func (s *Store) FinishMirrorJob(id int64, status, errText string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE mirror_jobs SET status=?, error=?, updated_at=? WHERE id=?`, status, errText, now(), id)
	return err
}

// CountMirrorQueue counts jobs that are not done.
func (s *Store) CountMirrorQueue() (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM mirror_jobs WHERE status IN ('queued','error')`).Scan(&n)
	return n, err
}

// Backup is a git bundle record.
type Backup struct {
	ID        int64  `json:"id"`
	RepoID    int64  `json:"repoId"`
	Path      string `json:"path"`
	SHA256    string `json:"sha256"`
	CreatedAt string `json:"createdAt"`
}

// AddBackup records a bundle.
func (s *Store) AddBackup(b *Backup) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	b.CreatedAt = now()
	res, err := s.db.Exec(`INSERT INTO backups(repo_id, path, sha256, created_at) VALUES(?,?,?,?)`,
		b.RepoID, b.Path, b.SHA256, b.CreatedAt)
	if err != nil {
		return err
	}
	b.ID, _ = res.LastInsertId()
	return nil
}

// ListBackups returns recent bundles.
func (s *Store) ListBackups(limit int) ([]Backup, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if limit <= 0 {
		limit = 20
	}
	rows, err := s.db.Query(`SELECT id, repo_id, path, sha256, created_at FROM backups ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Backup
	for rows.Next() {
		var b Backup
		if err := rows.Scan(&b.ID, &b.RepoID, &b.Path, &b.SHA256, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// LatestBackup returns the newest bundle or ErrNotFound.
func (s *Store) LatestBackup() (Backup, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var b Backup
	err := s.db.QueryRow(`SELECT id, repo_id, path, sha256, created_at FROM backups ORDER BY id DESC LIMIT 1`).
		Scan(&b.ID, &b.RepoID, &b.Path, &b.SHA256, &b.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Backup{}, ErrNotFound
	}
	return b, err
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func encodeLabels(labels []string) string {
	if len(labels) == 0 {
		return "[]"
	}
	parts := make([]string, 0, len(labels))
	for _, l := range labels {
		l = strings.TrimSpace(l)
		if l == "" {
			continue
		}
		parts = append(parts, `"`+strings.ReplaceAll(l, `"`, ``)+`"`)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func decodeLabels(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "[]" {
		return []string{}
	}
	raw = strings.TrimPrefix(raw, "[")
	raw = strings.TrimSuffix(raw, "]")
	if raw == "" {
		return []string{}
	}
	chunks := strings.Split(raw, ",")
	out := make([]string, 0, len(chunks))
	for _, c := range chunks {
		c = strings.Trim(strings.TrimSpace(c), `"`)
		if c != "" {
			out = append(out, c)
		}
	}
	return out
}

func scanIssues(rows *sql.Rows) ([]Issue, error) {
	var out []Issue
	for rows.Next() {
		item, err := scanIssueRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func scanIssueRow(sc interface{ Scan(...any) error }) (Issue, error) {
	var item Issue
	var labels string
	err := sc.Scan(&item.ID, &item.RepoID, &item.Number, &item.Title, &item.Body, &item.Status, &labels, &item.CreatedAt, &item.UpdatedAt)
	item.Labels = decodeLabels(labels)
	return item, err
}

// Counts is the sidebar badge summary.
type Counts struct {
	Repos   int `json:"repos"`
	Pulls   int `json:"pulls"`
	Issues  int `json:"issues"`
	Failed  int `json:"failed"`
	Queue   int `json:"queue"`
	Release int `json:"releases"`
}

// Counts returns sidebar numbers.
func (s *Store) Counts() (Counts, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var c Counts
	queries := []struct {
		dest *int
		q    string
	}{
		{&c.Repos, `SELECT COUNT(*) FROM repos`},
		{&c.Pulls, `SELECT COUNT(*) FROM pulls WHERE status='open'`},
		{&c.Issues, `SELECT COUNT(*) FROM issues WHERE status!='done'`},
		{&c.Queue, `SELECT COUNT(*) FROM mirror_jobs WHERE status IN ('queued','error')`},
		{&c.Release, `SELECT COUNT(*) FROM releases`},
	}
	for _, item := range queries {
		if err := s.db.QueryRow(item.q).Scan(item.dest); err != nil {
			return Counts{}, err
		}
	}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM (
		SELECT repo_id FROM ci_runs r WHERE status='failure' AND id = (SELECT MAX(id) FROM ci_runs WHERE repo_id=r.repo_id)
	)`).Scan(&c.Failed); err != nil {
		return Counts{}, fmt.Errorf("failed counts: %w", err)
	}
	return c, nil
}
