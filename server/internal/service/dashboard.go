package service

import (
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/J3ckJ/EL-Workspace/server/internal/store"
)

// Dashboard is the overview payload.
func (s *Service) Dashboard() (map[string]any, error) {
	repos, err := s.Store.ListRepos()
	if err != nil {
		return nil, err
	}
	counts, err := s.Store.Counts()
	if err != nil {
		return nil, err
	}
	cards := make([]map[string]any, 0, len(repos))
	var week []map[string]any
	var activity []map[string]any
	mirrored, localOnly := 0, 0
	for _, repo := range repos {
		card := s.repoCard(repo)
		cards = append(cards, card)
		week = append(week, s.week(repo))
		activity = append(activity, s.recentActivity(repo)...)
		switch repo.MirrorMode {
		case "local":
			localOnly++
		default:
			if repo.MirrorURL != "" {
				mirrored++
			} else {
				localOnly++
			}
		}
	}
	sort.Slice(activity, func(i, j int) bool {
		return activity[i]["date"].(string) > activity[j]["date"].(string)
	})
	if len(activity) > 8 {
		activity = activity[:8]
	}
	attention := s.attention(repos)
	var clone map[string]any
	if len(repos) > 0 {
		pick := repos[0]
		for _, repo := range repos {
			if repo.Pinned {
				pick = repo
				break
			}
		}
		sshURL, httpURL := s.CloneURLs(pick.Owner, pick.Name)
		clone = map[string]any{"owner": pick.Owner, "name": pick.Name, "ssh": sshURL, "http": httpURL, "command": "git clone " + sshURL}
	}
	host, _ := os.Hostname()
	queue, _ := s.Store.CountMirrorQueue()
	backup := map[string]any{"time": s.Store.Setting("backup_time", "03:00"), "ok": false, "label": "ещё не было"}
	if b, err := s.Store.LatestBackup(); err == nil {
		backup["ok"] = true
		backup["at"] = b.CreatedAt
		backup["label"] = backupLabel(b.CreatedAt)
	}
	return map[string]any{
		"name": s.DisplayName(), "host": host, "owner": s.Owner(),
		"repoCount": len(repos), "mirrored": mirrored, "localOnly": localOnly,
		"attention": attention, "week": week, "repos": cards, "activity": activity,
		"clone": clone, "counts": counts, "queue": queue, "backup": backup,
		"link": s.linkState(repos, queue),
		"server": map[string]any{
			"host": host, "http": s.PublicHTTP(), "sshPort": s.SSHPort,
			"queue": queue, "backup": backup, "os": runtime.GOOS,
		},
	}, nil
}

// Link is the mirror queue and the latest CI run. Counts come from stored jobs.
func (s *Service) Link() (map[string]any, error) {
	repos, err := s.Store.ListRepos()
	if err != nil {
		return nil, err
	}
	queue, err := s.Store.CountMirrorQueue()
	if err != nil {
		return nil, err
	}
	host, _ := os.Hostname()
	out := s.linkState(repos, queue)
	out["host"] = host
	return out, nil
}

func (s *Service) linkState(repos []store.Repo, queue int) map[string]any {
	names := map[int64]store.Repo{}
	synced, offline, conflict, ahead := 0, 0, 0, 0
	for _, repo := range repos {
		names[repo.ID] = repo
		if repo.MirrorMode == "local" || repo.MirrorURL == "" {
			continue
		}
		switch repo.MirrorStatus {
		case "offline":
			offline++
		case "conflict":
			conflict++
		case "ahead":
			ahead++
			synced++
		default:
			synced++
		}
	}
	jobs, _ := s.Store.DueMirrorJobs()
	queued := make([]map[string]any, 0, len(jobs))
	for _, job := range jobs {
		repo := names[job.RepoID]
		queued = append(queued, map[string]any{
			"id": job.ID, "owner": repo.Owner, "name": repo.Name,
			"ref": job.Ref, "status": job.Status, "error": job.Error, "createdAt": job.CreatedAt,
		})
	}
	phase := "idle"
	switch {
	case conflict > 0:
		phase = "conflict"
	case queue > 0 || offline > 0:
		phase = "offline"
	case synced > 0:
		phase = "synced"
	}
	var ci map[string]any
	if runs, err := s.Store.ListCIRuns(0, 1); err == nil && len(runs) > 0 {
		run := runs[0]
		repo := names[run.RepoID]
		if repo.Name == "" {
			if loaded, err := s.Store.GetRepoByID(run.RepoID); err == nil {
				repo = loaded
			}
		}
		ci = map[string]any{
			"id": run.ID, "status": run.Status, "ref": run.Ref, "workflow": run.Workflow,
			"owner": repo.Owner, "name": repo.Name, "at": run.FinishedAt,
		}
		if run.Status == "running" || run.Status == "queued" {
			phase = "ci"
		}
	}
	pulls, _ := s.Store.ListPulls(0)
	incoming := 0
	for _, pull := range pulls {
		if pull.Status == "open" {
			incoming++
		}
	}
	return map[string]any{
		"phase": phase, "queue": queue, "synced": synced, "offline": offline,
		"conflict": conflict, "ahead": ahead, "incoming": incoming,
		"jobs": queued, "ci": ci,
	}
}

func (s *Service) repoCard(repo store.Repo) map[string]any {
	path, _ := s.RepoPath(repo.Owner, repo.Name)
	card := map[string]any{
		"owner": repo.Owner, "name": repo.Name, "description": repo.Description,
		"pinned": repo.Pinned, "mirrorMode": repo.MirrorMode, "mirrorStatus": repo.MirrorStatus,
		"branch": repo.DefaultBranch, "language": "", "version": "", "subject": "",
		"status": "local", "updatedAt": repo.CreatedAt,
	}
	if !s.Git.HasCommit(path) {
		card["subject"] = "Пустой репозиторий"
		return card
	}
	if files, err := s.Git.ListFiles(path, repo.DefaultBranch); err == nil {
		card["language"] = languageOf(files)
	}
	card["version"] = s.Git.LatestTag(path)
	if branches, err := s.Git.Branches(path); err == nil && len(branches) > 0 {
		card["branch"] = branches[0].Name
		card["subject"] = branches[0].Subject
		card["updatedAt"] = branches[0].Date.UTC().Format(time.RFC3339)
	}
	switch {
	case repo.MirrorMode == "local" || repo.MirrorURL == "":
		card["status"] = "local"
	case repo.MirrorStatus == "offline":
		card["status"] = "offline"
	case repo.MirrorStatus == "conflict":
		card["status"] = "conflict"
	case repo.MirrorStatus == "ahead":
		card["status"] = "ahead"
	default:
		card["status"] = "synced"
	}
	if runs, err := s.Store.ListCIRuns(repo.ID, 5); err == nil {
		for _, run := range runs {
			if run.Status == "running" || run.Status == "queued" {
				continue
			}
			card["ci"] = run.Status
			card["ciRef"] = run.Ref
			card["ciId"] = run.ID
			if run.Status == "failure" {
				card["status"] = "failed"
			}
			break
		}
	}
	return card
}

func (s *Service) week(repo store.Repo) map[string]any {
	path, _ := s.RepoPath(repo.Owner, repo.Name)
	days := []int{0, 0, 0, 0, 0, 0, 0}
	now := time.Now()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).AddDate(0, 0, -6)
	if dates, err := s.Git.Dates(path, start); err == nil {
		for _, d := range dates {
			local := d.In(now.Location())
			idx := int(local.Sub(start).Hours()) / 24
			if idx >= 0 && idx < 7 {
				days[idx]++
			}
		}
	}
	return map[string]any{"name": repo.Name, "owner": repo.Owner, "days": days, "branch": repo.DefaultBranch}
}

func (s *Service) recentActivity(repo store.Repo) []map[string]any {
	path, err := s.RepoPath(repo.Owner, repo.Name)
	if err != nil || !s.Git.HasCommit(path) {
		return nil
	}
	commits, err := s.Git.Log(path, "--all", 5)
	if err != nil {
		return nil
	}
	var out []map[string]any
	version := s.Git.LatestTag(path)
	for _, c := range commits {
		item := map[string]any{
			"owner": repo.Owner, "name": repo.Name, "sha": c.SHA, "short": c.Short,
			"subject": c.Subject, "date": c.Date.UTC().Format(time.RFC3339),
		}
		if version != "" && strings.Contains(c.Subject, version) {
			item["tag"] = version
		}
		out = append(out, item)
	}
	return out
}

func (s *Service) attention(repos []store.Repo) map[string]any {
	for _, repo := range repos {
		runs, err := s.Store.ListCIRuns(repo.ID, 8)
		if err != nil {
			continue
		}
		for _, run := range runs {
			if run.Status == "failure" {
				return map[string]any{
					"kind": "ci", "tone": "danger",
					"kicker": "Сборка упала",
					"title":  repo.Name + " не собирается на ветке " + run.Ref,
					"detail": run.Reason, "owner": repo.Owner, "name": repo.Name,
					"ref": run.Ref, "id": run.ID, "at": run.FinishedAt,
					"action": "Открыть лог",
				}
			}
		}
	}
	pulls, _ := s.Store.ListPulls(0)
	for _, p := range pulls {
		if p.Status != "open" {
			continue
		}
		repo, err := s.Store.GetRepoByID(p.RepoID)
		if err != nil {
			continue
		}
		return map[string]any{
			"kind": "pr", "tone": "accent",
			"kicker": "Ждёт ревью",
			"title":  repo.Name + " · PR #" + itoa(p.Number),
			"detail": p.Title, "owner": repo.Owner, "name": repo.Name,
			"number": p.Number, "at": p.UpdatedAt, "action": "Открыть",
		}
	}
	return nil
}

func itoa(n int) string { return strconv.Itoa(n) }

func backupLabel(raw string) string {
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return raw
	}
	local := t.In(time.Now().Location())
	now := time.Now()
	clock := local.Format("15:04")
	if local.Year() == now.Year() && local.YearDay() == now.YearDay() {
		return "сегодня " + clock
	}
	if local.Year() == now.Year() && local.YearDay() == now.YearDay()-1 {
		return "вчера " + clock
	}
	return local.Format("02.01 15:04")
}

// Panel is the menu-bar / tray snapshot.
func (s *Service) Panel() (map[string]any, error) {
	dash, err := s.Dashboard()
	if err != nil {
		return nil, err
	}
	var items []map[string]any
	if att, ok := dash["attention"].(map[string]any); ok && att != nil {
		items = append(items, att)
	}
	pulls, _ := s.Store.ListPulls(0)
	for _, p := range pulls {
		if p.Status != "open" {
			continue
		}
		repo, err := s.Store.GetRepoByID(p.RepoID)
		if err != nil {
			continue
		}
		items = append(items, map[string]any{
			"kind": "pr", "title": repo.Name + " · PR #" + itoa(p.Number),
			"detail": "ждёт твоего ревью", "owner": repo.Owner, "name": repo.Name, "number": p.Number,
			"action": "Ревью",
		})
		if len(items) >= 4 {
			break
		}
	}
	var recent []map[string]any
	if cards, ok := dash["repos"].([]map[string]any); ok {
		for _, card := range cards {
			recent = append(recent, map[string]any{
				"name": card["name"], "branch": card["branch"], "status": card["status"],
				"owner": card["owner"],
			})
			if len(recent) >= 4 {
				break
			}
		}
	}
	server, _ := dash["server"].(map[string]any)
	return map[string]any{
		"host": dash["host"], "sshPort": s.SSHPort, "http": s.PublicHTTP(),
		"queue": dash["queue"], "backup": dash["backup"], "items": items, "recent": recent,
		"link": dash["link"], "server": server,
	}, nil
}

// Search looks through code, commits and issues.
func (s *Service) Search(query string) (map[string]any, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return map[string]any{"code": []any{}, "commits": []any{}, "issues": []any{}, "repos": []any{}}, nil
	}
	repos, err := s.Store.ListRepos()
	if err != nil {
		return nil, err
	}
	var code []map[string]any
	var commits []map[string]any
	var repoHits []map[string]any
	lower := strings.ToLower(query)
	for _, repo := range repos {
		if strings.Contains(strings.ToLower(repo.Name), lower) || strings.Contains(strings.ToLower(repo.Description), lower) {
			repoHits = append(repoHits, map[string]any{"owner": repo.Owner, "name": repo.Name, "description": repo.Description})
		}
		path, err := s.RepoPath(repo.Owner, repo.Name)
		if err != nil || !s.Git.HasCommit(path) {
			continue
		}
		rev := repo.DefaultBranch
		hits, _ := s.Git.Grep(path, rev, query, 8)
		for _, hit := range hits {
			code = append(code, map[string]any{
				"owner": repo.Owner, "name": repo.Name, "path": hit.Path, "line": hit.Line, "text": hit.Text,
			})
			if len(code) >= 20 {
				break
			}
		}
		found, _ := s.Git.LogGrep(path, query, 5)
		for _, c := range found {
			commits = append(commits, map[string]any{
				"owner": repo.Owner, "name": repo.Name, "sha": c.SHA, "short": c.Short, "subject": c.Subject,
			})
		}
	}
	issues, _ := s.Store.ListIssues(0)
	var issueHits []map[string]any
	for _, issue := range issues {
		repo, err := s.Store.GetRepoByID(issue.RepoID)
		if err != nil {
			continue
		}
		if !matchIssue(query, issue) {
			continue
		}
		issueHits = append(issueHits, map[string]any{
			"id": issue.ID, "number": issue.Number, "title": issue.Title, "status": issue.Status,
			"owner": repo.Owner, "name": repo.Name, "labels": issue.Labels,
		})
	}
	return map[string]any{"code": nonNilSlice(code), "commits": nonNilSlice(commits), "issues": nonNilSlice(issueHits), "repos": nonNilSlice(repoHits)}, nil
}

func matchIssue(query string, issue store.Issue) bool {
	open := issue.Status != "done"
	text := strings.ToLower(issue.Title + " " + issue.Body + " " + strings.Join(issue.Labels, " "))
	for _, part := range strings.Fields(query) {
		lower := strings.ToLower(part)
		switch {
		case lower == "is:open":
			if !open {
				return false
			}
		case lower == "is:closed":
			if open {
				return false
			}
		case strings.HasPrefix(lower, "label:"):
			want := strings.TrimPrefix(lower, "label:")
			found := false
			for _, label := range issue.Labels {
				if strings.ToLower(label) == want {
					found = true
				}
			}
			if !found {
				return false
			}
		default:
			if !strings.Contains(text, lower) {
				return false
			}
		}
	}
	return true
}

func nonNilSlice(v []map[string]any) []map[string]any {
	if v == nil {
		return []map[string]any{}
	}
	return v
}

// FilteredIssues applies the search box query.
func (s *Service) FilteredIssues(owner, name, query string) ([]map[string]any, error) {
	var repoID int64
	repoName := map[int64]store.Repo{}
	if name != "" {
		repo, _, err := s.repo(owner, name)
		if err != nil {
			return nil, err
		}
		repoID = repo.ID
		repoName[repo.ID] = repo
	}
	issues, err := s.Store.ListIssues(repoID)
	if err != nil {
		return nil, err
	}
	var out []map[string]any
	for _, issue := range issues {
		if query != "" && !matchIssue(query, issue) {
			continue
		}
		repo, ok := repoName[issue.RepoID]
		if !ok {
			repo, err = s.Store.GetRepoByID(issue.RepoID)
			if err != nil {
				continue
			}
			repoName[issue.RepoID] = repo
		}
		out = append(out, map[string]any{
			"id": issue.ID, "number": issue.Number, "title": issue.Title, "body": issue.Body,
			"status": issue.Status, "labels": issue.Labels, "owner": repo.Owner, "name": repo.Name,
			"updatedAt": issue.UpdatedAt,
		})
	}
	if out == nil {
		out = []map[string]any{}
	}
	return out, nil
}
