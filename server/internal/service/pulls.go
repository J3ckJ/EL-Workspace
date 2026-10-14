package service

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/J3ckJ/EL-Workspace/server/internal/gitx"
	"github.com/J3ckJ/EL-Workspace/server/internal/store"
)

// CreateIssue adds a kanban card.
func (s *Service) CreateIssue(owner, name, title, body, status string, labels []string) (store.Issue, error) {
	repo, _, err := s.repo(owner, name)
	if err != nil {
		return store.Issue{}, err
	}
	if strings.TrimSpace(title) == "" {
		return store.Issue{}, bad(http.StatusBadRequest, "Нужен заголовок задачи.")
	}
	if status == "" {
		status = "backlog"
	}
	if !ValidIssueStatus(status) {
		return store.Issue{}, bad(http.StatusBadRequest, "Неизвестная колонка.")
	}
	issue := store.Issue{RepoID: repo.ID, Title: strings.TrimSpace(title), Body: body, Status: status, Labels: labels}
	if err := s.Store.CreateIssue(&issue); err != nil {
		return store.Issue{}, err
	}
	return issue, nil
}

// UpdateIssue moves or edits a card.
func (s *Service) UpdateIssue(id int64, title, body, status string, labels []string, setLabels bool) (store.Issue, error) {
	issue, err := s.Store.GetIssue(id)
	if err != nil {
		return store.Issue{}, bad(http.StatusNotFound, "Задача не найдена.")
	}
	if title != "" {
		issue.Title = title
	}
	if body != "" {
		issue.Body = body
	}
	if status != "" {
		if !ValidIssueStatus(status) {
			return store.Issue{}, bad(http.StatusBadRequest, "Неизвестная колонка.")
		}
		issue.Status = status
	}
	if setLabels {
		issue.Labels = labels
	}
	if err := s.Store.UpdateIssue(issue); err != nil {
		return store.Issue{}, err
	}
	return issue, nil
}

// CreatePull opens a pull request.
func (s *Service) CreatePull(owner, name, title, body, head, base string) (store.Pull, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return store.Pull{}, err
	}
	if base == "" {
		base = repo.DefaultBranch
	}
	if !validBranch(head) || !validBranch(base) || head == base {
		return store.Pull{}, bad(http.StatusBadRequest, "Укажите разные ветки.")
	}
	if _, err := s.Git.RevParse(path, head); err != nil {
		return store.Pull{}, bad(http.StatusBadRequest, "Ветка "+head+" не найдена.")
	}
	if _, err := s.Git.RevParse(path, base); err != nil {
		return store.Pull{}, bad(http.StatusBadRequest, "Ветка "+base+" не найдена.")
	}
	if strings.TrimSpace(title) == "" {
		title = head
	}
	p := store.Pull{RepoID: repo.ID, Title: strings.TrimSpace(title), Body: body, Head: head, Base: base}
	if err := s.Store.CreatePull(&p); err != nil {
		return store.Pull{}, err
	}
	s.enqueueCI(repo, head, mustSHA(s.Git, path, head), "pull_request")
	return p, nil
}

func mustSHA(g gitx.Runner, repo, rev string) string {
	sha, err := g.RevParse(repo, rev)
	if err != nil {
		return ""
	}
	return sha
}

// PullView is a pull request with diff and review state.
func (s *Service) PullView(owner, name string, number int) (map[string]any, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	p, err := s.Store.GetPull(repo.ID, number)
	if err != nil {
		return nil, bad(http.StatusNotFound, "Pull request не найден.")
	}
	files, _ := s.Diff(owner, name, "", p.Base, p.Head, false)
	comments, _ := s.Store.ListComments(repo.ID, fmt.Sprintf("pull:%d", number))
	mergeable := s.Git.Mergeable(path, p.Base, p.Head)
	linear := s.Git.IsAncestor(path, p.Base, p.Head)
	headSHA := mustSHA(s.Git, path, p.Head)
	runs, _ := s.Store.ListCIRuns(repo.ID, 20)
	ciStatus := ""
	for _, run := range runs {
		if run.Ref == p.Head && (headSHA == "" || run.SHA == headSHA || strings.HasPrefix(headSHA, run.SHA) || strings.HasPrefix(run.SHA, headSHA)) {
			ciStatus = run.Status
			break
		}
	}
	unresolved := 0
	for _, c := range comments {
		if !c.Resolved {
			unresolved++
		}
	}
	if comments == nil {
		comments = []store.Comment{}
	}
	return map[string]any{
		"pull": p, "files": files, "comments": comments,
		"mergeable": mergeable, "linear": linear, "ci": ciStatus,
		"unresolved": unresolved, "headSha": headSHA,
		"mirrorMode": repo.MirrorMode, "mirrorUrl": repo.MirrorURL,
	}, nil
}

// AddComment stores an inline comment. A fenced suggestion is kept separately.
func (s *Service) AddComment(owner, name, target, filePath, body, author string, line int) (store.Comment, error) {
	repo, _, err := s.repo(owner, name)
	if err != nil {
		return store.Comment{}, err
	}
	if strings.TrimSpace(body) == "" {
		return store.Comment{}, bad(http.StatusBadRequest, "Пустой комментарий.")
	}
	if author == "" {
		author = s.DisplayName()
	}
	suggestion := extractSuggestion(body)
	c := store.Comment{
		RepoID: repo.ID, Target: target, Path: filePath, Line: line,
		Body: body, Suggestion: suggestion, Author: author,
	}
	if err := s.Store.CreateComment(&c); err != nil {
		return store.Comment{}, err
	}
	return c, nil
}

func extractSuggestion(body string) string {
	const open = "```suggestion"
	i := strings.Index(body, open)
	if i < 0 {
		return ""
	}
	rest := body[i+len(open):]
	if nl := strings.IndexByte(rest, '\n'); nl >= 0 {
		rest = rest[nl+1:]
	}
	end := strings.Index(rest, "```")
	if end < 0 {
		return ""
	}
	return strings.TrimRight(rest[:end], "\n")
}

// ApplySuggestion commits the suggested replacement onto the pull request head.
func (s *Service) ApplySuggestion(id int64) (string, error) {
	c, err := s.Store.GetComment(id)
	if err != nil {
		return "", bad(http.StatusNotFound, "Комментарий не найден.")
	}
	if c.Suggestion == "" {
		return "", bad(http.StatusBadRequest, "В комментарии нет правки.")
	}
	repo, err := s.Store.GetRepoByID(c.RepoID)
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(c.Target, "pull:") {
		return "", bad(http.StatusBadRequest, "Правка применяется к pull request.")
	}
	var number int
	if _, err := fmt.Sscanf(c.Target, "pull:%d", &number); err != nil {
		return "", bad(http.StatusBadRequest, "Некорректная цель комментария.")
	}
	p, err := s.Store.GetPull(repo.ID, number)
	if err != nil || p.Status != "open" {
		return "", bad(http.StatusBadRequest, "Pull request уже закрыт.")
	}
	unlock := s.lock(repo.ID)
	defer unlock()
	path, err := s.RepoPath(repo.Owner, repo.Name)
	if err != nil {
		return "", err
	}
	old, newSHA, err := s.Git.ReplaceLines(path, p.Head, c.Path, c.Line, c.Suggestion,
		fmt.Sprintf("Применить правку к %s", c.Path))
	if err != nil {
		return "", bad(http.StatusBadRequest, err.Error())
	}
	s.HandleRefs(repo.Owner, repo.Name, []gitx.RefChange{{Ref: "refs/heads/" + p.Head, Old: old, New: newSHA}})
	_ = s.Store.ResolveComment(c.ID, true)
	return newSHA, nil
}

// MergePull integrates a pull request with merge, squash or rebase.
func (s *Service) MergePull(owner, name string, number int, method string) (string, error) {
	switch method {
	case "merge", "squash", "rebase", "":
		if method == "" {
			method = "merge"
		}
	default:
		return "", bad(http.StatusBadRequest, "Способ слияния: merge, squash или rebase.")
	}
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return "", err
	}
	p, err := s.Store.GetPull(repo.ID, number)
	if err != nil {
		return "", bad(http.StatusNotFound, "Pull request не найден.")
	}
	if p.Status != "open" {
		return "", bad(http.StatusConflict, "Pull request уже закрыт.")
	}
	unlock := s.lock(repo.ID)
	defer unlock()
	old, _ := s.Git.RevParse(path, p.Base)
	message := mergeMessage(method, p)
	sha, err := s.Git.Merge(path, p.Base, p.Head, method, message)
	if err != nil {
		return "", bad(http.StatusConflict, err.Error())
	}
	if err := s.Store.FinishPull(repo.ID, number, "merged", sha); err != nil {
		return "", err
	}
	s.closeFromRange(repo, path, old, sha, p.Title+"\n"+p.Body)
	if repo.MirrorMode == "push" || repo.MirrorMode == "both" {
		_, _ = s.Store.EnqueueMirror(repo.ID, "refs/heads/"+p.Base, false)
	}
	s.enqueueCI(repo, p.Base, sha, "push")
	return sha, nil
}

func mergeMessage(method string, p store.Pull) string {
	switch method {
	case "squash":
		msg := fmt.Sprintf("%s (#%d)", p.Title, p.Number)
		if strings.TrimSpace(p.Body) != "" {
			msg += "\n\n" + p.Body
		}
		return msg
	case "rebase":
		return p.Title
	default:
		msg := fmt.Sprintf("Merge pull request #%d from %s\n\n%s", p.Number, p.Head, p.Title)
		if strings.TrimSpace(p.Body) != "" {
			msg += "\n\n" + p.Body
		}
		return msg
	}
}

// CherryPick applies a commit onto the default branch.
func (s *Service) CherryPick(owner, name, sha, branch string) (string, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return "", err
	}
	if branch == "" {
		branch = repo.DefaultBranch
	}
	if !validBranch(branch) || !isSHA(sha) {
		return "", bad(http.StatusBadRequest, "Нужны ветка и коммит.")
	}
	unlock := s.lock(repo.ID)
	defer unlock()
	old, newSHA, err := s.Git.CherryPick(path, branch, sha)
	if err != nil {
		return "", bad(http.StatusConflict, err.Error())
	}
	s.HandleRefs(owner, name, []gitx.RefChange{{Ref: "refs/heads/" + branch, Old: old, New: newSHA}})
	return newSHA, nil
}

// CheckoutInfo tells the CLI which branch to fetch.
func (s *Service) CheckoutInfo(owner, name string, number int) (map[string]any, error) {
	repo, _, err := s.repo(owner, name)
	if err != nil {
		return nil, err
	}
	p, err := s.Store.GetPull(repo.ID, number)
	if err != nil {
		return nil, bad(http.StatusNotFound, "Pull request не найден.")
	}
	sshURL, httpURL := s.CloneURLs(owner, name)
	return map[string]any{"pull": p, "ssh": sshURL, "http": httpURL, "branch": p.Head}, nil
}
