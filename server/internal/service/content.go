package service

import (
	"net/http"
	"path"
	"strings"
	"time"

	"github.com/J3ckJ/EL-Workspace/server/internal/gitx"
	"github.com/J3ckJ/EL-Workspace/server/internal/store"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
)

var markdown = goldmark.New(goldmark.WithExtensions(extension.GFM))

// CommitView is a commit plus its patch.
type CommitView struct {
	gitx.Commit
	Files    []gitx.FileDiff `json:"files"`
	Comments []any           `json:"comments"`
}

// Log returns commits for a branch, tag or the default branch.
func (s *Service) Log(owner, name, rev string, limit int) ([]gitx.Commit, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	if rev == "" {
		rev = repo.DefaultBranch
	}
	if !validBranch(rev) && !isSHA(rev) {
		return nil, bad(http.StatusBadRequest, "Некорректная ревизия.")
	}
	commits, err := s.Git.Log(path, rev, limit)
	if err != nil {
		return []gitx.Commit{}, nil
	}
	if commits == nil {
		commits = []gitx.Commit{}
	}
	return commits, nil
}

func isSHA(s string) bool {
	if len(s) < 7 || len(s) > 40 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= '0' && r <= '9', r >= 'a' && r <= 'f', r >= 'A' && r <= 'F':
		default:
			return false
		}
	}
	return true
}

// Commit loads one commit and its diff.
func (s *Service) Commit(owner, name, sha string, ignoreSpace bool) (map[string]any, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	commits, err := s.Git.Log(path, sha, 1)
	if err != nil || len(commits) == 0 || !strings.HasPrefix(commits[0].SHA, sha) && commits[0].SHA != sha {
		if len(commits) == 0 || !strings.HasPrefix(commits[0].SHA, sha) {
			return nil, bad(http.StatusNotFound, "Коммит не найден.")
		}
	}
	patch, err := s.Git.ShowPatch(path, commits[0].SHA, ignoreSpace)
	if err != nil {
		return nil, bad(http.StatusInternalServerError, err.Error())
	}
	comments, _ := s.Store.ListComments(repo.ID, "commit:"+commits[0].SHA)
	if comments == nil {
		comments = []store.Comment{}
	}
	return map[string]any{
		"commit":   commits[0],
		"files":    emptyDiff(gitx.ParseDiff(patch)),
		"comments": comments,
	}, nil
}

// Diff returns a structured diff between base and head, or for one commit.
func (s *Service) Diff(owner, name, sha, base, head string, ignoreSpace bool) ([]gitx.FileDiff, error) {
	_, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	var text string
	switch {
	case sha != "":
		text, err = s.Git.ShowPatch(path, sha, ignoreSpace)
	case base != "" && head != "":
		text, err = s.Git.DiffText(path, ignoreSpace, base+"..."+head)
		if err != nil {
			text, err = s.Git.DiffText(path, ignoreSpace, base, head)
		}
	default:
		return nil, bad(http.StatusBadRequest, "Нужен коммит или пара веток.")
	}
	if err != nil {
		return nil, bad(http.StatusBadRequest, err.Error())
	}
	return emptyDiff(gitx.ParseDiff(text)), nil
}

func emptyDiff(files []gitx.FileDiff) []gitx.FileDiff {
	if files == nil {
		return []gitx.FileDiff{}
	}
	return files
}

// Tree lists a directory.
func (s *Service) Tree(owner, name, rev, dir string) (map[string]any, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	if rev == "" {
		rev = repo.DefaultBranch
	}
	dir, err = cleanRel(dir)
	if err != nil {
		return nil, err
	}
	if !s.Git.HasCommit(path) {
		return map[string]any{"ref": rev, "path": dir, "entries": []gitx.Entry{}, "empty": true}, nil
	}
	entries, err := s.Git.Tree(path, rev, dir)
	if err != nil {
		return nil, bad(http.StatusNotFound, "Путь не найден.")
	}
	if entries == nil {
		entries = []gitx.Entry{}
	}
	return map[string]any{"ref": rev, "path": dir, "entries": entries, "empty": false}, nil
}

// Blob returns file contents.
func (s *Service) Blob(owner, name, rev, file string) (map[string]any, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	if rev == "" {
		rev = repo.DefaultBranch
	}
	file, err = cleanRel(file)
	if err != nil || file == "" {
		return nil, bad(http.StatusBadRequest, "Нужен путь к файлу.")
	}
	content, binary, err := s.Git.Blob(path, rev, file)
	if err != nil {
		return nil, bad(http.StatusNotFound, "Файл не найден.")
	}
	body := ""
	if !binary {
		body = string(content)
	}
	return map[string]any{"path": file, "ref": rev, "binary": binary, "content": body, "size": len(content)}, nil
}

// Readme returns rendered markdown.
func (s *Service) Readme(owner, name, rev string) (map[string]any, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	if rev == "" {
		rev = repo.DefaultBranch
	}
	if !s.Git.HasCommit(path) {
		return map[string]any{"missing": true}, nil
	}
	file, raw, err := s.Git.Readme(path, rev)
	if err != nil || file == "" {
		return map[string]any{"missing": true}, nil
	}
	var buf strings.Builder
	if err := markdown.Convert(raw, &buf); err != nil {
		return map[string]any{"name": file, "html": "<pre>" + htmlEscape(string(raw)) + "</pre>"}, nil
	}
	return map[string]any{"name": file, "html": buf.String(), "missing": false}, nil
}

func htmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}

// Refs lists branches and tags.
func (s *Service) Refs(owner, name string) (map[string]any, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	branches, _ := s.Git.Branches(path)
	tags, _ := s.Git.Tags(path)
	if branches == nil {
		branches = []gitx.Branch{}
	}
	if tags == nil {
		tags = []gitx.Tag{}
	}
	return map[string]any{
		"defaultBranch": repo.DefaultBranch,
		"branches":      branches,
		"tags":          tags,
		"version":       s.Git.LatestTag(path),
	}, nil
}

// Summary is the repository page header.
func (s *Service) Summary(owner, name string) (map[string]any, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	sshURL, httpURL := s.CloneURLs(owner, name)
	branches, _ := s.Git.Branches(path)
	language := ""
	version := ""
	branch := repo.DefaultBranch
	var updated time.Time
	subject := ""
	if s.Git.HasCommit(path) {
		files, _ := s.Git.ListFiles(path, repo.DefaultBranch)
		language = languageOf(files)
		version = s.Git.LatestTag(path)
		if len(branches) > 0 {
			branch = branches[0].Name
			updated = branches[0].Date
			subject = branches[0].Subject
		}
	}
	return map[string]any{
		"repo":      repo,
		"ssh":       sshURL,
		"http":      httpURL,
		"language":  language,
		"version":   version,
		"branch":    branch,
		"updatedAt": updated,
		"subject":   subject,
		"empty":     !s.Git.HasCommit(path),
		"clone":     "git clone " + sshURL,
	}, nil
}

func languageOf(files []string) string {
	counts := map[string]int{}
	for _, file := range files {
		lang := extLang(path.Ext(file))
		if lang != "" {
			counts[lang]++
		}
	}
	type pair struct {
		k string
		n int
	}
	var best []pair
	for k, n := range counts {
		best = append(best, pair{k, n})
	}
	if len(best) == 0 {
		return ""
	}
	for i := 0; i < len(best); i++ {
		for j := i + 1; j < len(best); j++ {
			if best[j].n > best[i].n {
				best[i], best[j] = best[j], best[i]
			}
		}
	}
	if len(best) > 1 && best[1].n*2 >= best[0].n {
		return best[0].k + " · " + best[1].k
	}
	return best[0].k
}

func extLang(ext string) string {
	switch strings.ToLower(ext) {
	case ".py":
		return "Python"
	case ".ts", ".tsx":
		return "TypeScript"
	case ".js", ".jsx":
		return "JavaScript"
	case ".go":
		return "Go"
	case ".cs":
		return "C#"
	case ".swift":
		return "Swift"
	case ".ps1":
		return "PowerShell"
	case ".rs":
		return "Rust"
	case ".c", ".h":
		return "C"
	default:
		return ""
	}
}

func nonNil(v any) any {
	if v == nil {
		return []any{}
	}
	return v
}
