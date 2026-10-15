package service

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/J3ckJ/EL-Workspace/server/internal/store"
)

// ReleaseNotes drafts notes from CHANGELOG and commits since the previous tag.
func (s *Service) ReleaseNotes(owner, name, tag string) (string, error) {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return "", err
	}
	if !s.Git.HasCommit(path) {
		return "", bad(http.StatusBadRequest, "В репозитории ещё нет коммитов.")
	}
	var b strings.Builder
	if raw, bin, err := s.Git.Blob(path, repo.DefaultBranch, "CHANGELOG.md"); err == nil && !bin {
		if section := extractChangelog(string(raw), tag); section != "" {
			b.WriteString(section)
			b.WriteString("\n")
		}
	}
	prev := s.previousTag(path, tag)
	spec := repo.DefaultBranch
	if prev != "" {
		spec = prev + ".." + repo.DefaultBranch
	}
	text, err := s.Git.Messages(path, spec)
	if err == nil && strings.TrimSpace(text) != "" {
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString("Коммиты с прошлого тега:\n")
		for _, block := range strings.Split(text, "---") {
			line := strings.TrimSpace(block)
			if line == "" {
				continue
			}
			subject := strings.Split(line, "\n")[0]
			b.WriteString("- ")
			b.WriteString(subject)
			b.WriteString("\n")
		}
	}
	if b.Len() == 0 {
		b.WriteString("Релиз ")
		b.WriteString(tag)
		b.WriteString("\n")
	}
	return strings.TrimSpace(b.String()), nil
}

func (s *Service) previousTag(path, tag string) string {
	tags, err := s.Git.Tags(path)
	if err != nil {
		return ""
	}
	for _, item := range tags {
		if item.Name != tag {
			return item.Name
		}
	}
	return ""
}

func extractChangelog(text, tag string) string {
	ver := strings.TrimPrefix(tag, "v")
	lines := strings.Split(text, "\n")
	start := -1
	for i, line := range lines {
		if !strings.HasPrefix(line, "#") {
			continue
		}
		if strings.Contains(line, tag) || strings.Contains(line, ver) {
			start = i
			break
		}
	}
	if start < 0 {
		return ""
	}
	end := len(lines)
	for i := start + 1; i < len(lines); i++ {
		if strings.HasPrefix(lines[i], "## ") {
			end = i
			break
		}
	}
	return strings.TrimSpace(strings.Join(lines[start:end], "\n"))
}

// CreateRelease tags the default branch and stores notes and assets.
// fromCI attaches every file written to EL_ARTIFACTS by the latest green run.
func (s *Service) CreateRelease(owner, name, tag, title, notes string, publish, fromCI bool, assets []AssetIn) (store.Release, error) {
	if !validTag(tag) {
		return store.Release{}, bad(http.StatusBadRequest, "Некорректный тег.")
	}
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return store.Release{}, err
	}
	sha, err := s.Git.RevParse(path, repo.DefaultBranch)
	if err != nil {
		return store.Release{}, bad(http.StatusBadRequest, "Нет коммита для тега.")
	}
	if strings.TrimSpace(notes) == "" {
		notes, _ = s.ReleaseNotes(owner, name, tag)
	}
	if strings.TrimSpace(title) == "" {
		title = tag
	}
	unlock := s.lock(repo.ID)
	defer unlock()
	if err := s.Git.AnnotatedTag(path, tag, title+"\n\n"+notes, sha); err != nil {
		return store.Release{}, bad(http.StatusConflict, "Не удалось создать тег: "+err.Error())
	}
	rel := store.Release{RepoID: repo.ID, Tag: tag, Title: title, Notes: notes, Published: false}
	if err := s.Store.CreateRelease(&rel); err != nil {
		return store.Release{}, bad(http.StatusConflict, "Такой релиз уже есть.")
	}
	if fromCI {
		found, err := s.ciAssets(repo.ID)
		if err != nil {
			return rel, err
		}
		assets = append(assets, found...)
	}
	for _, asset := range assets {
		if err := s.storeAsset(&rel, asset); err != nil {
			return rel, err
		}
	}
	rel, _ = s.Store.GetReleaseByTag(repo.ID, tag)
	s.HandleRefs(owner, name, nil)
	if publish {
		if err := s.PublishRelease(owner, name, tag); err != nil {
			return rel, err
		}
		rel, _ = s.Store.GetReleaseByTag(repo.ID, tag)
	} else if repo.MirrorMode == "push" || repo.MirrorMode == "both" {
		_, _ = s.Store.EnqueueMirror(repo.ID, "refs/tags/"+tag, false)
	}
	return rel, nil
}

// AssetIn is an uploaded release file.
type AssetIn struct {
	Name string
	Body []byte
}

func (s *Service) ciAssets(repoID int64) ([]AssetIn, error) {
	runs, err := s.Store.ListCIRuns(repoID, 30)
	if err != nil {
		return nil, err
	}
	var runID int64
	for _, run := range runs {
		if run.Status == "success" {
			runID = run.ID
			break
		}
	}
	if runID == 0 {
		return nil, bad(http.StatusBadRequest, "Нет успешной сборки с файлами.")
	}
	dir := filepath.Join(s.Data, "ci", fmt.Sprintf("%d", runID))
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, bad(http.StatusBadRequest, "Успешная сборка не оставила файлов.")
	}
	var out []AssetIn
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		body, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			return nil, err
		}
		out = append(out, AssetIn{Name: entry.Name(), Body: body})
	}
	if len(out) == 0 {
		return nil, bad(http.StatusBadRequest, "Успешная сборка не оставила файлов.")
	}
	return out, nil
}

func (s *Service) storeAsset(rel *store.Release, asset AssetIn) error {
	name := strings.TrimSpace(asset.Name)
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "\\") || name == "." || name == ".." {
		return bad(http.StatusBadRequest, "Некорректное имя файла.")
	}
	sum := sha256.Sum256(asset.Body)
	hexSum := hex.EncodeToString(sum[:])
	dest := fmt.Sprintf("%s/assets/%d-%s", s.Data, rel.ID, name)
	if err := writeFile(dest, asset.Body); err != nil {
		return err
	}
	item := store.Asset{ReleaseID: rel.ID, Name: name, StoredPath: dest, SHA256: hexSum, Size: int64(len(asset.Body))}
	return s.Store.AddAsset(&item)
}

// PublishRelease pushes the tag and, when a token is set, opens a GitHub release.
func (s *Service) PublishRelease(owner, name, tag string) error {
	repo, path, err := s.repo(owner, name)
	if err != nil {
		return err
	}
	rel, err := s.Store.GetReleaseByTag(repo.ID, tag)
	if err != nil {
		return bad(http.StatusNotFound, "Релиз не найден.")
	}
	if repo.MirrorURL == "" {
		return bad(http.StatusBadRequest, "У репозитория нет зеркала.")
	}
	if err := s.Git.Push(path, repo.MirrorURL, "refs/tags/"+tag, "refs/tags/"+tag, false); err != nil {
		return bad(http.StatusBadGateway, "Не удалось отправить тег: "+err.Error())
	}
	token := s.Store.Setting("github_token", "")
	if ghOwner, ghRepo, ok := githubRepo(repo.MirrorURL); ok && token != "" {
		if err := createGitHubRelease(token, ghOwner, ghRepo, rel); err != nil {
			return bad(http.StatusBadGateway, err.Error())
		}
	}
	return s.Store.MarkReleasePublished(rel.ID)
}

func githubRepo(raw string) (owner, repo string, ok bool) {
	raw = strings.TrimSuffix(raw, ".git")
	switch {
	case strings.Contains(raw, "github.com:"):
		parts := strings.Split(raw, "github.com:")
		segs := strings.Split(parts[len(parts)-1], "/")
		if len(segs) >= 2 {
			return segs[len(segs)-2], segs[len(segs)-1], true
		}
	case strings.Contains(raw, "github.com/"):
		parts := strings.Split(raw, "github.com/")
		segs := strings.Split(parts[len(parts)-1], "/")
		if len(segs) >= 2 {
			return segs[0], segs[1], true
		}
	}
	return "", "", false
}

func createGitHubRelease(token, owner, repo string, rel store.Release) error {
	body, _ := json.Marshal(map[string]any{
		"tag_name": rel.Tag,
		"name":     rel.Title,
		"body":     rel.Notes,
	})
	req, err := http.NewRequest(http.MethodPost, "https://api.github.com/repos/"+owner+"/"+repo+"/releases", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 20 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 400))
		return fmt.Errorf("GitHub ответил %d: %s", res.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

// LatestCIArtifacts returns files from the newest successful run.
func (s *Service) LatestCIArtifacts(owner, name string) (string, string, error) {
	repo, _, err := s.repo(owner, name)
	if err != nil {
		return "", "", err
	}
	runs, err := s.Store.ListCIRuns(repo.ID, 30)
	if err != nil {
		return "", "", err
	}
	for _, run := range runs {
		if run.Status == "success" {
			return run.Ref, run.SHA, nil
		}
	}
	return "", "", bad(http.StatusBadRequest, "Нет успешной сборки.")
}

func validTag(tag string) bool {
	if len(tag) < 2 || len(tag) > 80 || strings.Contains(tag, "..") {
		return false
	}
	for _, r := range tag {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '_', r == '-', r == '+':
		default:
			return false
		}
	}
	return true
}
