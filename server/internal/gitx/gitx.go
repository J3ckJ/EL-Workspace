// Package gitx wraps the system git binary. Pack protocol, merges and diffs
// stay in git itself so the server does not reimplement them.
package gitx

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const ZeroHash = "0000000000000000000000000000000000000000"

// Runner executes git with a fixed environment.
type Runner struct {
	Env []string
}

// Run executes git and returns stdout.
func (r Runner) Run(dir string, args ...string) (string, error) {
	return r.RunEnv(dir, nil, args...)
}

// RunEnv executes git with extra environment entries.
func (r Runner) RunEnv(dir string, extra []string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = append(append([]string{}, r.Env...), extra...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return stdout.String(), fmt.Errorf("%s", firstLine(msg))
	}
	return stdout.String(), nil
}

// Stream connects git stdin/stdout for the pack protocol.
func (r Runner) Stream(dir string, stdin io.Reader, stdout, stderr io.Writer, args ...string) error {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = r.Env
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	if stderr == nil {
		stderr = io.Discard
	}
	cmd.Stderr = stderr
	return cmd.Run()
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// InitBare creates an empty bare repository with HEAD on main.
func (r Runner) InitBare(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if _, err := r.Run("", "init", "--bare", "--initial-branch=main", path); err != nil {
		return err
	}
	_, err := r.Run(path, "config", "http.receivepack", "true")
	return err
}

// Refs lists heads and tags.
func (r Runner) Refs(repo string) (map[string]string, error) {
	out, err := r.Run(repo, "for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags")
	if err != nil {
		return nil, err
	}
	refs := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, " ", 2)
		if len(parts) == 2 {
			refs[parts[1]] = parts[0]
		}
	}
	return refs, nil
}

// RefChange is one updated ref.
type RefChange struct {
	Ref string
	Old string
	New string
}

// DiffRefs compares two ref snapshots.
func DiffRefs(before, after map[string]string) []RefChange {
	var out []RefChange
	seen := map[string]bool{}
	for ref, sha := range after {
		seen[ref] = true
		old := before[ref]
		if old == "" {
			old = ZeroHash
		}
		if old != sha {
			out = append(out, RefChange{Ref: ref, Old: old, New: sha})
		}
	}
	for ref, sha := range before {
		if !seen[ref] {
			out = append(out, RefChange{Ref: ref, Old: sha, New: ZeroHash})
		}
	}
	return out
}

// RevParse resolves a revision.
func (r Runner) RevParse(repo, rev string) (string, error) {
	out, err := r.Run(repo, "rev-parse", "--verify", rev)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

// Commit is a history entry.
type Commit struct {
	SHA     string    `json:"sha"`
	Parents []string  `json:"parents"`
	Author  string    `json:"author"`
	Email   string    `json:"email"`
	Date    time.Time `json:"date"`
	Subject string    `json:"subject"`
	Short   string    `json:"short"`
}

func parseCommitChunk(chunk string) (Commit, bool) {
	parts := strings.Split(chunk, "\x1f")
	if len(parts) < 6 {
		return Commit{}, false
	}
	c := Commit{
		SHA:     parts[0],
		Author:  parts[2],
		Email:   parts[3],
		Subject: parts[5],
	}
	if parts[1] != "" {
		c.Parents = strings.Fields(parts[1])
	}
	if t, err := time.Parse(time.RFC3339, parts[4]); err == nil {
		c.Date = t
	}
	if len(c.SHA) >= 7 {
		c.Short = c.SHA[:7]
	}
	return c, true
}

// Log returns recent commits for a revision.
func (r Runner) Log(repo, rev string, limit int) ([]Commit, error) {
	if limit <= 0 {
		limit = 50
	}
	args := []string{"log", fmt.Sprintf("-n%d", limit), "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e"}
	if rev != "" {
		args = append(args, rev)
	} else {
		args = append(args, "--all")
	}
	out, err := r.Run(repo, args...)
	if err != nil {
		if strings.Contains(err.Error(), "does not have any commits") || strings.Contains(err.Error(), "bad revision") || strings.Contains(err.Error(), "ambiguous argument") {
			return []Commit{}, nil
		}
		return nil, err
	}
	return parseLog(out), nil
}

func parseLog(out string) []Commit {
	var commits []Commit
	for _, chunk := range strings.Split(out, "\x1e") {
		chunk = strings.TrimSpace(chunk)
		if chunk == "" {
			continue
		}
		if c, ok := parseCommitChunk(chunk); ok {
			commits = append(commits, c)
		}
	}
	return commits
}

// Messages returns subject and body text for a revision or a range.
func (r Runner) Messages(repo, spec string) (string, error) {
	out, err := r.Run(repo, "log", "--format=%s%n%b%n---", spec)
	if err != nil {
		return "", err
	}
	return out, nil
}

// Branch is a local branch.
type Branch struct {
	Name    string    `json:"name"`
	SHA     string    `json:"sha"`
	Date    time.Time `json:"date"`
	Subject string    `json:"subject"`
}

// Branches lists local branches, newest first.
func (r Runner) Branches(repo string) ([]Branch, error) {
	out, err := r.Run(repo, "for-each-ref", "--sort=-committerdate",
		"--format=%(refname:short)%x00%(objectname)%x00%(committerdate:iso-strict)%x00%(subject)", "refs/heads")
	if err != nil {
		return nil, err
	}
	var outB []Branch
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		p := strings.Split(line, "\x00")
		if len(p) < 4 {
			continue
		}
		b := Branch{Name: p[0], SHA: p[1], Subject: p[3]}
		if t, err := time.Parse(time.RFC3339, p[2]); err == nil {
			b.Date = t
		}
		outB = append(outB, b)
	}
	return outB, nil
}

// Tag is an annotated or lightweight tag.
type Tag struct {
	Name    string    `json:"name"`
	SHA     string    `json:"sha"`
	Date    time.Time `json:"date"`
	Subject string    `json:"subject"`
}

// Tags lists tags, newest first.
func (r Runner) Tags(repo string) ([]Tag, error) {
	out, err := r.Run(repo, "for-each-ref", "--sort=-creatordate",
		"--format=%(refname:short)%x00%(objectname)%x00%(creatordate:iso-strict)%x00%(subject)", "refs/tags")
	if err != nil {
		return nil, err
	}
	var tags []Tag
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		p := strings.Split(line, "\x00")
		if len(p) < 4 {
			continue
		}
		tag := Tag{Name: p[0], SHA: p[1], Subject: p[3]}
		if t, err := time.Parse(time.RFC3339, p[2]); err == nil {
			tag.Date = t
		}
		tags = append(tags, tag)
	}
	return tags, nil
}

// LatestTag returns the most recent tag name.
func (r Runner) LatestTag(repo string) string {
	tags, err := r.Tags(repo)
	if err != nil || len(tags) == 0 {
		return ""
	}
	return tags[0].Name
}

// Entry is one tree row.
type Entry struct {
	Mode string `json:"mode"`
	Type string `json:"type"`
	Name string `json:"name"`
	Path string `json:"path"`
	SHA  string `json:"sha"`
}

// Tree lists one directory.
func (r Runner) Tree(repo, rev, dir string) ([]Entry, error) {
	spec := rev
	if dir != "" && dir != "." {
		spec = rev + ":" + dir
	}
	out, err := r.Run(repo, "ls-tree", spec)
	if err != nil {
		return nil, err
	}
	var entries []Entry
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		// <mode> SP <type> SP <object> TAB <file>
		tab := strings.IndexByte(line, '\t')
		if tab < 0 {
			continue
		}
		meta := strings.Fields(line[:tab])
		if len(meta) < 3 {
			continue
		}
		name := line[tab+1:]
		path := name
		if dir != "" && dir != "." {
			path = dir + "/" + name
		}
		entries = append(entries, Entry{Mode: meta[0], Type: meta[1], SHA: meta[2], Name: name, Path: path})
	}
	return entries, nil
}

// Blob reads a file from a revision. binary is true when the content contains NUL.
func (r Runner) Blob(repo, rev, path string) ([]byte, bool, error) {
	cmd := exec.Command("git", "show", rev+":"+path)
	cmd.Dir = repo
	cmd.Env = r.Env
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, false, fmt.Errorf("%s", firstLine(msg))
	}
	b := stdout.Bytes()
	if len(b) > 1_000_000 {
		return b[:1_000_000], bytes.Contains(b[:1_000_000], []byte{0}), fmt.Errorf("файл больше 1 МБ")
	}
	return b, bytes.Contains(b, []byte{0}), nil
}

// ListFiles returns every file path at rev.
func (r Runner) ListFiles(repo, rev string) ([]string, error) {
	out, err := r.Run(repo, "ls-tree", "-r", "--name-only", rev)
	if err != nil {
		return nil, err
	}
	var files []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line != "" {
			files = append(files, line)
		}
	}
	return files, nil
}

// Grep searches file contents.
func (r Runner) Grep(repo, rev, query string, limit int) ([]SearchHit, error) {
	if strings.TrimSpace(query) == "" {
		return nil, nil
	}
	out, err := r.Run(repo, "grep", "-n", "-I", "-F", "-e", query, rev)
	if err != nil {
		return nil, nil
	}
	var hits []SearchHit
	for _, line := range strings.Split(out, "\n") {
		if line == "" {
			continue
		}
		// rev:path:line:text  — path may confuse split. git grep -n prints path:line:text
		// with rev prefix when rev is given: "rev:path:line:content"
		rest := line
		if strings.HasPrefix(rest, rev+":") {
			rest = strings.TrimPrefix(rest, rev+":")
		}
		parts := strings.SplitN(rest, ":", 3)
		if len(parts) < 3 {
			continue
		}
		hits = append(hits, SearchHit{Path: parts[0], Line: parts[1], Text: parts[2]})
		if limit > 0 && len(hits) >= limit {
			break
		}
	}
	return hits, nil
}

// SearchHit is one grep match.
type SearchHit struct {
	Path string
	Line string
	Text string
}

// LogGrep searches commit messages.
func (r Runner) LogGrep(repo, query string, limit int) ([]Commit, error) {
	if limit <= 0 {
		limit = 10
	}
	out, err := r.Run(repo, "log", "--all", fmt.Sprintf("-n%d", limit), "--regexp-ignore-case", "--fixed-strings", "--grep", query,
		"--format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e")
	if err != nil {
		return nil, nil
	}
	return parseLog(out), nil
}

// Dates returns commit timestamps since the given time.
func (r Runner) Dates(repo string, since time.Time) ([]time.Time, error) {
	out, err := r.Run(repo, "log", "--all", "--since="+since.UTC().Format(time.RFC3339), "--format=%cI")
	if err != nil {
		return nil, nil
	}
	var times []time.Time
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		if t, err := time.Parse(time.RFC3339, line); err == nil {
			times = append(times, t)
		}
	}
	return times, nil
}

// DiffText returns a unified diff.
func (r Runner) DiffText(repo string, ignoreSpace bool, args ...string) (string, error) {
	full := []string{"diff", "--no-color", "--unified=3"}
	if ignoreSpace {
		full = append(full, "-w")
	}
	full = append(full, args...)
	out, err := r.Run(repo, full...)
	if err != nil {
		return "", err
	}
	if len(out) > 500_000 {
		out = out[:500_000]
	}
	return out, nil
}

// ShowPatch returns the patch of one commit.
func (r Runner) ShowPatch(repo, sha string, ignoreSpace bool) (string, error) {
	args := []string{"show", "--format=", "--no-color", "--unified=3", "--patch"}
	if ignoreSpace {
		args = append(args, "-w")
	}
	args = append(args, sha)
	out, err := r.Run(repo, args...)
	if err != nil {
		return "", err
	}
	if len(out) > 500_000 {
		out = out[:500_000]
	}
	return out, nil
}

// IsAncestor reports whether ancestor is contained in rev.
func (r Runner) IsAncestor(repo, ancestor, rev string) bool {
	_, err := r.Run(repo, "merge-base", "--is-ancestor", ancestor, rev)
	return err == nil
}

// Mergeable reports whether head merges cleanly into base.
func (r Runner) Mergeable(repo, base, head string) bool {
	_, err := r.Run(repo, "merge-tree", "--write-tree", base, head)
	return err == nil
}

// HasCommit reports whether the repository has at least one commit.
func (r Runner) HasCommit(repo string) bool {
	_, err := r.Run(repo, "rev-parse", "--verify", "HEAD")
	return err == nil
}

// LostCommits lists commits reachable from remoteRef and not from localRev.
func (r Runner) LostCommits(repo, localRev, remoteRef string) ([]Commit, error) {
	out, err := r.Run(repo, "log", "--format=%H%x1f%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e", remoteRef, "--not", localRev)
	if err != nil {
		return nil, err
	}
	return parseLog(out), nil
}

// Fetch updates a remote-tracking ref without moving local branches.
func (r Runner) Fetch(repo, url, refspec string) error {
	_, err := r.Run(repo, "fetch", "--no-tags", url, refspec)
	return err
}

// Push sends a ref to a remote URL or filesystem path.
func (r Runner) Push(repo, url, src, dst string, force bool) error {
	args := []string{"push"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, url, src+":"+dst)
	_, err := r.Run(repo, args...)
	return err
}

// AnnotatedTag creates an annotated tag.
func (r Runner) AnnotatedTag(repo, name, message, sha string) error {
	_, err := r.Run(repo, "tag", "-a", name, sha, "-m", message)
	return err
}

// Bundle writes a git bundle of every ref.
func (r Runner) Bundle(repo, dest string) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	_, err := r.Run(repo, "bundle", "create", dest, "--all")
	return err
}

// Readme picks a README from the tree root.
func (r Runner) Readme(repo, rev string) (string, []byte, error) {
	for _, name := range []string{"README.md", "README.MD", "Readme.md", "README"} {
		b, binary, err := r.Blob(repo, rev, name)
		if err == nil && !binary {
			return name, b, nil
		}
	}
	return "", nil, nil
}
