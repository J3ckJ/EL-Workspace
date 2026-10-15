// Package demo fills a fresh data directory with the repositories shown in
// the product screens, using real commits, a real pull request and real CI.
package demo

import (
	"fmt"
	"path/filepath"
	"time"

	"github.com/J3ckJ/EL-Workspace/server/internal/service"
)

// Seed creates sample repositories once.
func Seed(svc *service.Service) error {
	existing, err := svc.Store.ListRepos()
	if err != nil {
		return err
	}
	if len(existing) > 0 {
		return nil
	}
	svc.SetHooks(false)
	defer svc.SetHooks(true)
	now := time.Now().UTC()
	if err := seedFlyDrop(svc, now); err != nil {
		return err
	}
	if err := seedAppRestore(svc, now); err != nil {
		return err
	}
	if err := seedTransport(svc, now); err != nil {
		return err
	}
	if err := seedSmartHome(svc, now); err != nil {
		return err
	}
	if err := seedWorkspace(svc, now); err != nil {
		return err
	}
	if err := seedProfile(svc, now); err != nil {
		return err
	}
	_, err = svc.BackupNow()
	return err
}

func seedFlyDrop(svc *service.Service, now time.Time) error {
	repo, err := svc.CreateRepo("FlyDrop", "Передача файлов между Mac и Windows в локальной сети.", "push", "", true)
	if err != nil {
		return err
	}
	mirror := filepath.Join(svc.Data, "mirrors", "FlyDrop.git")
	if err := svc.Git.InitBare(mirror); err != nil {
		return err
	}
	repo.MirrorURL = mirror
	if err := svc.Store.UpdateRepo(repo); err != nil {
		return err
	}
	files := map[string]string{
		"README.md":                flyDropReadme(false),
		"CHANGELOG.md":             "# История\n\n## 0.3.0\n\n- Трей Windows и тёмная иконка.\n",
		"LICENSE":                  "MIT\n",
		".github/workflows/ci.yml": "name: ci\non: [push]\njobs:\n  test:\n    runs-on: self-hosted\n    steps:\n      - name: Проверка\n        run: |\n          echo \"windows + macos matrix ok\"\n          mkdir -p artifacts\n          echo ok > artifacts/FlyDrop-0.3.0.txt\n",
		"FlyDrop.Mac":              "share sheet\n",
		"FlyDrop.Win":              "tray icon\n",
	}
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "main", "Initial commit", now.AddDate(0, -2, 0), map[string]string{"LICENSE": "MIT\n"}); err != nil {
		return err
	}
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "main", "Windows: первые шаги", now.Add(-48*time.Hour), files); err != nil {
		return err
	}
	files["README.md"] = flyDropReadme(true)
	files["FlyDrop.Win"] = "tray icon dark mode\n"
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "main", "Windows: первые шаги в README", now.Add(-26*time.Hour), files); err != nil {
		return err
	}
	if _, err := svc.RunWorkflows(repo.Owner, repo.Name, "main", "push"); err != nil {
		return err
	}
	if _, err := svc.CreateRelease(repo.Owner, repo.Name, "v0.3.0", "FlyDrop 0.3.0", "", false, false, nil); err != nil {
		return err
	}
	_, _ = svc.Store.EnqueueMirror(repo.ID, "refs/heads/main", false)
	svc.DrainMirrors()
	return nil
}

func flyDropReadme(fixed bool) string {
	step := "1. Скачайте FlyDrop-0.3.0.exe из Releases.\n2. Разрешите доступ в брандмауэре Windows для частных сетей.\n3. Откройте FlyDrop на Mac — устройства найдут друг друга.\n"
	if fixed {
		step = "1. Установите через winget и скачайте .exe из Releases:\n\n```\nwinget install J3ckJ.FlyDrop\n```\n\n2. Разрешите доступ в брандмауэре Windows для частных сетей.\n3. Откройте FlyDrop на Mac. Оба устройства должны быть в одной сети.\n"
	}
	return "# FlyDrop\n\nПередача файлов между Mac и Windows в локальной сети — без облака и аккаунтов.\n\n## Первые шаги на Windows\n\n" + step
}

func seedAppRestore(svc *service.Service, now time.Time) error {
	repo, err := svc.CreateRepo("AppRestore", "Пауза. Главная функция недоступна: установщик, которым никто не пользовался.", "local", "", true)
	if err != nil {
		return err
	}
	base := map[string]string{
		"README.md":                "# AppRestore\n\nРабочая версия без главной функции.\n",
		"CHANGELOG.md":             "# История\n\n## [0.4.0] — 2026-10-13\n\nРабочая версия без главной функции: Apple закрыла установку приложений, которые никогда не скачивались.\nРазработка на паузе.\n\n## [0.3.0]\n\n- Предыдущая ветка.\n",
		"requirements.txt":         "PySide6\n",
		".github/workflows/ci.yml": appWorkflow,
	}
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "main", "AppRestore 0.4.0", now.Add(-72*time.Hour), base); err != nil {
		return err
	}
	if _, err := svc.CreateRelease(repo.Owner, repo.Name, "v0.4.0", "v0.4.0", "", false, false, []service.AssetIn{
		{Name: "AppRestore-0.4.0.dmg", Body: []byte("dmg-placeholder")},
		{Name: "AppRestore-0.4.0-win.zip", Body: []byte("zip-placeholder")},
	}); err != nil {
		return err
	}
	broken := map[string]string{}
	for k, v := range base {
		broken[k] = v
	}
	broken["notes.txt"] = "redesign\n"
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "cursor/redesign-704e", "Редизайн списка", now.Add(-4*time.Minute), broken); err != nil {
		return err
	}
	runs, err := svc.RunWorkflows(repo.Owner, repo.Name, "cursor/redesign-704e", "push")
	if err != nil {
		return err
	}
	if len(runs) == 0 || runs[0].Status != "failure" {
		return fmt.Errorf("ожидалась упавшая сборка AppRestore")
	}
	return nil
}

const appWorkflow = `name: test
on: [push, pull_request]
jobs:
  windows:
    name: windows · test
    runs-on: [self-hosted, Windows]
    steps:
      - name: Установка зависимостей
        run: |
          echo "$ pip install -r requirements.txt"
          echo "Collecting PySide6"
          echo "ERROR: No matching distribution found for PySide6"
          echo "$ pip install lzfse"
          echo "error: Microsoft Visual C++ 14.0 or greater is required"
          echo "Process exited with code 1"
          exit 1
  macos:
    name: macos · test
    runs-on: [self-hosted, macOS]
    steps:
      - name: Тест
        run: |
          echo "ERROR: runner mac-mini.local · 31 c"
          exit 1
`

func seedTransport(svc *service.Service, now time.Time) error {
	repo, err := svc.CreateRepo("Transport-Master", "Столица: развязки, кортежи, службы.", "push", "", false)
	if err != nil {
		return err
	}
	mirror := filepath.Join(svc.Data, "mirrors", "Transport-Master.git")
	if err := svc.Git.InitBare(mirror); err != nil {
		return err
	}
	repo.MirrorURL = mirror
	if err := svc.Store.UpdateRepo(repo); err != nil {
		return err
	}
	mainFile := "export type Route = { left: number; innermost: number }\nexport const Vehicle = { police: 'police' }\nexport function closeLanes(route: Route, ahead: number) {}\nexport const escort = { follow(_lead: string, _gap: number) {} }\n\nfunc spawnCortege(route: Route) {\n  let lead = Vehicle(.police, lane: route.left)\n  escort.follow(lead, gap: 25)\n}\n"
	next := "export type Route = { left: number; innermost: number }\nexport const Vehicle = { police: 'police' }\nexport function closeLanes(route: Route, ahead: number) {}\nexport const escort = { follow(_lead: string, _gap: number) {} }\n\nfunc spawnCortege(route: Route) {\n  let lead = Vehicle(.police, lane: route.innermost)\n  lead.siren = true\n  closeLanes(route, ahead: 400)\n  escort.follow(lead, gap: 25)\n}\n"
	wf := "name: ci\non: [push, pull_request]\njobs:\n  smoke:\n    name: ci/sim-smoke\n    runs-on: self-hosted\n    steps:\n      - run: echo smoke-ok\n"
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "main", "Каркас симуляции", now.Add(-10*24*time.Hour), map[string]string{
		"src/sim/cortege.ts":       mainFile,
		".github/workflows/ci.yml": wf,
	}); err != nil {
		return err
	}
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "cursor/city-sim", "Кортеж: внутренняя полоса", now.Add(-3*time.Hour), map[string]string{
		"src/sim/cortege.ts":       next,
		".github/workflows/ci.yml": wf,
	}); err != nil {
		return err
	}
	if _, err := svc.RunWorkflows(repo.Owner, repo.Name, "cursor/city-sim", "push"); err != nil {
		return err
	}
	pr, err := svc.CreatePull(repo.Owner, repo.Name, "Столица: развязки, кортежи, службы", "Перекрытие полос для кортежа.", "cursor/city-sim", "main")
	if err != nil {
		return err
	}
	_, err = svc.AddComment(repo.Owner, repo.Name, fmt.Sprintf("pull:%d", pr.Number), "src/sim/cortege.ts",
		"400 метров мало для МКАД. Давай брать из скорости: v × 12 с.\n\n```suggestion\n  closeLanes(route, ahead: speed * 12)\n```\n", "Евгений", 9)
	_, _ = svc.Store.EnqueueMirror(repo.ID, "refs/heads/main", false)
	svc.DrainMirrors()
	return err
}

func seedSmartHome(svc *service.Service, now time.Time) error {
	repo, err := svc.CreateRepo("smart-home", "Квартира, розетки и станции. Только локально.", "local", "", true)
	if err != nil {
		return err
	}
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "design/v3", "Экран «Дом»", now.Add(-6*time.Hour), map[string]string{
		"README.md":  "# smart-home\n\nТолько локально.\n",
		"Home.swift": "struct HomeView {}\n",
	}); err != nil {
		return err
	}
	cards := []struct {
		title, status, label string
	}{
		{"Сокеты: перерисовать по фото", "backlog", "дизайн"},
		{"3D-квартира по плану", "backlog", "3d"},
		{"Глагол: статус станций", "backlog", "api"},
		{"Экран «Дом»", "progress", "дизайн"},
		{"SberBox 2: ADB по Wi-Fi", "progress", "tv"},
	}
	for _, card := range cards {
		if _, err := svc.CreateIssue(repo.Owner, repo.Name, card.title, "", card.status, []string{card.label}); err != nil {
			return err
		}
	}
	return nil
}

func seedWorkspace(svc *service.Service, now time.Time) error {
	repo, err := svc.CreateRepo("EL-Workspace", "Лаунчер и локальный Git-хост.", "both", "", false)
	if err != nil {
		return err
	}
	mirror := filepath.Join(svc.Data, "mirrors", "EL-Workspace.git")
	if err := svc.Git.InitBare(mirror); err != nil {
		return err
	}
	body := map[string]string{
		"README.md": "# EL Workspace\n\nCI зелёный.\n",
		"VERSION":   "0.1.2\n",
	}
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "main", "EL Workspace 0.1.2", now.Add(-14*24*time.Hour), body); err != nil {
		return err
	}
	repo.MirrorURL = mirror
	if err := svc.Store.UpdateRepo(repo); err != nil {
		return err
	}
	_, _ = svc.Store.EnqueueMirror(repo.ID, "refs/heads/main", false)
	svc.DrainMirrors()
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "main", "Локальный хост: очередь зеркала", now.Add(-2*time.Hour), map[string]string{
		"README.md": "# EL Workspace\n\nCI зелёный.\n\nОдин коммит ещё не ушёл на зеркало.\n",
		"VERSION":   "0.1.2\n",
	}); err != nil {
		return err
	}
	repo, _ = svc.Store.GetRepo(repo.Owner, repo.Name)
	repo.MirrorStatus = "ahead"
	repo.MirrorDetail = "1 коммит ещё не отправлен"
	return svc.Store.UpdateRepo(repo)
}

func seedProfile(svc *service.Service, now time.Time) error {
	repo, err := svc.CreateRepo("github-profile", "Карточки профиля.", "push", "", false)
	if err != nil {
		return err
	}
	mirror := filepath.Join(svc.Data, "mirrors", "github-profile.git")
	if err := svc.Git.InitBare(mirror); err != nil {
		return err
	}
	repo.MirrorURL = mirror
	if err := svc.Store.UpdateRepo(repo); err != nil {
		return err
	}
	if _, err := svc.WriteCommit(repo.Owner, repo.Name, "main", "Карточки обновляются по расписанию", now.Add(-30*time.Hour), map[string]string{
		"README.md": "# profile\n",
	}); err != nil {
		return err
	}
	_, _ = svc.Store.EnqueueMirror(repo.ID, "refs/heads/main", false)
	svc.DrainMirrors()
	if _, err := svc.CreateIssue(repo.Owner, repo.Name, "README уровня AppRestore", "", "done", []string{"docs"}); err != nil {
		return err
	}
	if _, err := svc.CreateIssue(repo.Owner, repo.Name, "Авторы коммитов", "", "done", []string{"git"}); err != nil {
		return err
	}
	_, err = svc.CreateIssue(repo.Owner, repo.Name, "Версии в профиле", "", "done", []string{"ci"})
	return err
}
