package gitx

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// CommitFiles writes files and creates a commit on branch.
// Missing branches are created. The returned SHAs are the previous and new tips.
func (r Runner) CommitFiles(repo, branch string, files map[string]string, message string, when time.Time) (string, string, error) {
	if strings.TrimSpace(message) == "" {
		return "", "", fmt.Errorf("пустое сообщение коммита")
	}
	date := when.UTC().Format(time.RFC3339)
	extra := []string{"GIT_AUTHOR_DATE=" + date, "GIT_COMMITTER_DATE=" + date}
	_, err := r.RevParse(repo, "refs/heads/"+branch)
	if err != nil {
		if !r.HasCommit(repo) {
			return r.firstCommit(repo, branch, files, message, extra)
		}
		base := "HEAD"
		if _, errBase := r.RevParse(repo, "refs/heads/main"); errBase == nil {
			base = "refs/heads/main"
		}
		if _, err := r.Run(repo, "branch", branch, base); err != nil {
			return "", "", err
		}
	}
	old, err := r.RevParse(repo, branch)
	if err != nil {
		return "", "", err
	}
	wt, err := os.MkdirTemp("", "el-commit-")
	if err != nil {
		return "", "", err
	}
	defer os.RemoveAll(wt)
	if _, err := r.Run(repo, "worktree", "add", "--detach", wt, old); err != nil {
		return "", "", err
	}
	defer func() { _, _ = r.Run(repo, "worktree", "remove", "--force", wt) }()
	if err := writeFiles(wt, files); err != nil {
		return "", "", err
	}
	if _, err := r.Run(wt, "add", "-A"); err != nil {
		return "", "", err
	}
	if _, err := r.RunEnv(wt, extra, "commit", "-m", message); err != nil {
		return "", "", err
	}
	newSHA, err := r.RevParse(wt, "HEAD")
	if err != nil {
		return "", "", err
	}
	if _, err := r.Run(repo, "update-ref", "refs/heads/"+branch, newSHA, old); err != nil {
		return "", "", err
	}
	return old, newSHA, nil
}

func (r Runner) firstCommit(repo, branch string, files map[string]string, message string, extra []string) (string, string, error) {
	wt, err := os.MkdirTemp("", "el-init-")
	if err != nil {
		return "", "", err
	}
	defer os.RemoveAll(wt)
	if _, err := r.Run(wt, "init", "--initial-branch="+branch); err != nil {
		return "", "", err
	}
	if _, err := r.Run(wt, "remote", "add", "origin", repo); err != nil {
		return "", "", err
	}
	if err := writeFiles(wt, files); err != nil {
		return "", "", err
	}
	if _, err := r.Run(wt, "add", "-A"); err != nil {
		return "", "", err
	}
	if _, err := r.RunEnv(wt, extra, "commit", "-m", message); err != nil {
		return "", "", err
	}
	if _, err := r.Run(wt, "push", "origin", "HEAD:refs/heads/"+branch); err != nil {
		return "", "", err
	}
	newSHA, err := r.RevParse(repo, "refs/heads/"+branch)
	return ZeroHash, newSHA, err
}

func writeFiles(root string, files map[string]string) error {
	for path, content := range files {
		clean := filepath.Clean(path)
		if strings.HasPrefix(clean, "..") || filepath.IsAbs(clean) {
			return fmt.Errorf("небезопасный путь %s", path)
		}
		full := filepath.Join(root, clean)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// Merge integrates head into base using merge, squash or rebase.
// The base branch is updated only after a clean result.
func (r Runner) Merge(repo, baseBranch, headBranch, method, message string) (string, error) {
	switch method {
	case "merge", "squash", "rebase":
	default:
		return "", fmt.Errorf("неизвестный способ слияния")
	}
	base, err := r.RevParse(repo, baseBranch)
	if err != nil {
		return "", fmt.Errorf("ветка %s не найдена", baseBranch)
	}
	head, err := r.RevParse(repo, headBranch)
	if err != nil {
		return "", fmt.Errorf("ветка %s не найдена", headBranch)
	}
	if base == head {
		return "", fmt.Errorf("ветки указывают на один коммит")
	}
	wt, err := os.MkdirTemp("", "el-merge-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(wt)
	if _, err := r.Run(repo, "worktree", "add", "--detach", wt, base); err != nil {
		return "", err
	}
	defer func() { _, _ = r.Run(repo, "worktree", "remove", "--force", wt) }()

	switch method {
	case "squash":
		if _, err := r.Run(wt, "merge", "--squash", head); err != nil {
			return "", fmt.Errorf("конфликт при squash")
		}
		if _, err := r.Run(wt, "commit", "-m", message); err != nil {
			return "", fmt.Errorf("squash не создал изменений")
		}
	case "rebase":
		if _, err := r.Run(wt, "checkout", "--detach", head); err != nil {
			return "", err
		}
		if _, err := r.Run(wt, "rebase", base); err != nil {
			_, _ = r.Run(wt, "rebase", "--abort")
			return "", fmt.Errorf("конфликт при rebase")
		}
	case "merge":
		if _, err := r.Run(wt, "merge", "--no-ff", "--no-commit", head); err != nil {
			return "", fmt.Errorf("конфликт при слиянии")
		}
		if _, err := r.Run(wt, "commit", "-m", message); err != nil {
			return "", fmt.Errorf("слияние не создало коммит")
		}
	}
	newSHA, err := r.RevParse(wt, "HEAD")
	if err != nil {
		return "", err
	}
	if _, err := r.Run(repo, "update-ref", "refs/heads/"+baseBranch, newSHA, base); err != nil {
		return "", err
	}
	return newSHA, nil
}

// ReplaceLines replaces a 1-based line in a file on branch and commits.
func (r Runner) ReplaceLines(repo, branch, path string, line int, replacement, message string) (string, string, error) {
	if line < 1 {
		return "", "", fmt.Errorf("строка не указана")
	}
	old, err := r.RevParse(repo, branch)
	if err != nil {
		return "", "", err
	}
	wt, err := os.MkdirTemp("", "el-suggest-")
	if err != nil {
		return "", "", err
	}
	defer os.RemoveAll(wt)
	if _, err := r.Run(repo, "worktree", "add", "--detach", wt, old); err != nil {
		return "", "", err
	}
	defer func() { _, _ = r.Run(repo, "worktree", "remove", "--force", wt) }()
	full := filepath.Join(wt, filepath.Clean(path))
	raw, err := os.ReadFile(full)
	if err != nil {
		return "", "", fmt.Errorf("файл не найден")
	}
	lines := strings.Split(string(raw), "\n")
	// Keep a trailing empty element from a final newline out of the index math:
	// Split("a\n") == ["a", ""]. A file with a trailing newline has an extra empty.
	trailing := strings.HasSuffix(string(raw), "\n")
	body := lines
	if trailing && len(body) > 0 && body[len(body)-1] == "" {
		body = body[:len(body)-1]
	}
	if line > len(body) {
		return "", "", fmt.Errorf("нет строки %d", line)
	}
	repl := strings.Split(replacement, "\n")
	next := append([]string{}, body[:line-1]...)
	next = append(next, repl...)
	next = append(next, body[line:]...)
	text := strings.Join(next, "\n")
	if trailing || strings.HasSuffix(replacement, "\n") {
		text += "\n"
	}
	if err := os.WriteFile(full, []byte(text), 0o644); err != nil {
		return "", "", err
	}
	if _, err := r.Run(wt, "add", "--", path); err != nil {
		return "", "", err
	}
	if _, err := r.Run(wt, "commit", "-m", message); err != nil {
		return "", "", err
	}
	newSHA, err := r.RevParse(wt, "HEAD")
	if err != nil {
		return "", "", err
	}
	if _, err := r.Run(repo, "update-ref", "refs/heads/"+branch, newSHA, old); err != nil {
		return "", "", err
	}
	return old, newSHA, nil
}

// CherryPick applies one commit onto branch.
func (r Runner) CherryPick(repo, branch, sha string) (string, string, error) {
	old, err := r.RevParse(repo, branch)
	if err != nil {
		return "", "", err
	}
	wt, err := os.MkdirTemp("", "el-pick-")
	if err != nil {
		return "", "", err
	}
	defer os.RemoveAll(wt)
	if _, err := r.Run(repo, "worktree", "add", "--detach", wt, old); err != nil {
		return "", "", err
	}
	defer func() { _, _ = r.Run(repo, "worktree", "remove", "--force", wt) }()
	if _, err := r.Run(wt, "cherry-pick", sha); err != nil {
		return "", "", fmt.Errorf("cherry-pick не применился")
	}
	newSHA, err := r.RevParse(wt, "HEAD")
	if err != nil {
		return "", "", err
	}
	if _, err := r.Run(repo, "update-ref", "refs/heads/"+branch, newSHA, old); err != nil {
		return "", "", err
	}
	return old, newSHA, nil
}
