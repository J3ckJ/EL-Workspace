package api_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/J3ckJ/EL-Workspace/server/internal/api"
	"github.com/J3ckJ/EL-Workspace/server/internal/config"
	"github.com/J3ckJ/EL-Workspace/server/internal/githttp"
	"github.com/J3ckJ/EL-Workspace/server/internal/gitssh"
	"github.com/J3ckJ/EL-Workspace/server/internal/gitx"
	"github.com/J3ckJ/EL-Workspace/server/internal/service"
	"github.com/J3ckJ/EL-Workspace/server/internal/store"
	"golang.org/x/crypto/ssh"
)

type started struct {
	svc    *service.Service
	origin string
	ssh    int
	data   string
}

func boot(t *testing.T) *started {
	t.Helper()
	data := t.TempDir()
	if err := config.Prepare(data); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(filepath.Join(data, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	svc := service.New(data, st, gitx.Runner{Env: config.GitEnv(data)})
	svc.SetMirrorEvery(200 * time.Millisecond)
	httpLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	sshLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	svc.HTTPAddr = httpLn.Addr().String()
	svc.SSHPort = sshLn.Addr().(*net.TCPAddr).Port
	key := filepath.Join(data, "ssh", "host_ed25519")
	if err := gitssh.EnsureHostKey(key); err != nil {
		t.Fatal(err)
	}
	git := githttp.Host{Git: svc.Git, Path: svc.Resolve, Changed: svc.HandleRefs}
	sshHost := gitssh.Host{Git: svc.Git, Path: svc.Resolve, Changed: svc.HandleRefs, Allow: svc.AllowKey}
	svc.Start()
	t.Cleanup(func() {
		svc.Stop()
		_ = httpLn.Close()
		_ = sshLn.Close()
	})
	go func() { _ = sshHost.ServeListener(sshLn, key) }()
	go func() { _ = http.Serve(httpLn, (&api.Server{Svc: svc}).Handler(git)) }()
	return &started{svc: svc, origin: "http://" + svc.HTTPAddr, ssh: svc.SSHPort, data: data}
}

func (s *started) do(t *testing.T, method, path string, body any, dest any) *http.Response {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		reader = bytes.NewReader(raw)
	} else {
		reader = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, s.origin+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := readAll(res)
	if dest != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, dest); err != nil {
			t.Fatalf("decode %s: %v body %s", path, err, raw)
		}
	}
	res.Body = ioNop(raw)
	return res
}

func readAll(res *http.Response) ([]byte, error) {
	buf := new(bytes.Buffer)
	_, err := buf.ReadFrom(res.Body)
	return buf.Bytes(), err
}

func ioNop(b []byte) nopCloser { return nopCloser{bytes.NewReader(b)} }

type nopCloser struct{ *bytes.Reader }

func (nopCloser) Close() error { return nil }

func gitEnv(t *testing.T) []string {
	t.Helper()
	cfg := filepath.Join(t.TempDir(), "gitconfig")
	content := "[user]\n\tname = " + config.AuthorName + "\n\temail = " + config.AuthorEmail + "\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[safe]\n\tdirectory = *\n"
	if err := os.WriteFile(cfg, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return append(os.Environ(),
		"GIT_AUTHOR_NAME="+config.AuthorName,
		"GIT_AUTHOR_EMAIL="+config.AuthorEmail,
		"GIT_COMMITTER_NAME="+config.AuthorName,
		"GIT_COMMITTER_EMAIL="+config.AuthorEmail,
		"GIT_TERMINAL_PROMPT=0",
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL="+cfg,
	)
}

func runGit(t *testing.T, dir string, env []string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

func TestHostFlow(t *testing.T) {
	s := boot(t)
	env := gitEnv(t)
	var created struct {
		HTTP string `json:"http"`
		SSH  string `json:"ssh"`
	}
	res := s.do(t, http.MethodPost, "/api/repos", map[string]any{"name": "demo", "description": "flow"}, &created)
	if res.StatusCode != http.StatusCreated || !strings.Contains(created.HTTP, "/git/eugene/demo.git") {
		t.Fatalf("create %d %+v", res.StatusCode, created)
	}

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	authLine := string(ssh.MarshalAuthorizedKey(sshPub))
	res = s.do(t, http.MethodPost, "/api/keys", map[string]any{"title": "test", "key": authLine}, nil)
	if res.StatusCode != http.StatusCreated && res.StatusCode != http.StatusOK {
		t.Fatalf("key %d", res.StatusCode)
	}

	work := t.TempDir()
	runGit(t, "", env, "clone", created.HTTP, work)
	os.WriteFile(filepath.Join(work, "README.md"), []byte("# demo\n\nhello searchable\n"), 0o644)
	os.MkdirAll(filepath.Join(work, ".github", "workflows"), 0o755)
	os.WriteFile(filepath.Join(work, ".github", "workflows", "ci.yml"), []byte("name: sample\non: [push]\njobs:\n  test:\n    runs-on: self-hosted\n    steps:\n      - run: |\n          echo EL_CI_OK\n          mkdir -p artifacts\n          echo bundle > artifacts/notes.txt\n"), 0o644)
	runGit(t, work, env, "add", "-A")
	runGit(t, work, env, "commit", "-m", "first")
	runGit(t, work, env, "push", "origin", "HEAD:main")

	var runs []map[string]any
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		s.do(t, http.MethodGet, "/api/repos/eugene/demo/ci", nil, &runs)
		if len(runs) > 0 && runs[0]["status"] == "success" {
			break
		}
		time.Sleep(150 * time.Millisecond)
	}
	if len(runs) == 0 || runs[0]["status"] != "success" {
		t.Fatalf("ci %+v", runs)
	}
	if log, _ := runs[0]["log"].(string); !strings.Contains(log, "EL_CI_OK") {
		t.Fatalf("log %s", log)
	}

	var commitList []map[string]any
	s.do(t, http.MethodGet, "/api/repos/eugene/demo/commits?ref=main", nil, &commitList)
	if len(commitList) != 1 {
		t.Fatalf("commits %+v", commitList)
	}
	sha := commitList[0]["sha"].(string)
	var shown map[string]any
	s.do(t, http.MethodGet, "/api/repos/eugene/demo/commits/"+sha, nil, &shown)
	files, _ := shown["files"].([]any)
	if len(files) == 0 {
		t.Fatalf("diff %+v", shown)
	}

	sshWork := t.TempDir()
	keyFile := filepath.Join(t.TempDir(), "id")
	// OpenSSH private key via ssh-keygen is simpler than marshaling; use the generated key through ssh.MarshalPrivateKey.
	block, err := ssh.MarshalPrivateKey(priv, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(block), 0o600); err != nil {
		t.Fatal(err)
	}
	sshEnv := append(env, "GIT_SSH_COMMAND=ssh -i "+keyFile+" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "+itoa(s.ssh))
	runGit(t, "", sshEnv, "clone", created.SSH, sshWork)
	os.WriteFile(filepath.Join(sshWork, "ssh.txt"), []byte("from ssh\n"), 0o644)
	runGit(t, sshWork, sshEnv, "add", "ssh.txt")
	runGit(t, sshWork, sshEnv, "commit", "-m", "ssh change")
	runGit(t, sshWork, sshEnv, "push")

	s.do(t, http.MethodPost, "/api/repos/eugene/demo/issues", map[string]any{"title": "Socket", "body": "later"}, nil)
	runGit(t, work, env, "pull", "origin", "main")
	runGit(t, work, env, "checkout", "-b", "feature")
	os.WriteFile(filepath.Join(work, "README.md"), []byte("# demo\n\nhello searchable\n\nfeature\n"), 0o644)
	runGit(t, work, env, "add", "README.md")
	runGit(t, work, env, "commit", "-m", "fixes #1")
	runGit(t, work, env, "push", "origin", "HEAD:feature")
	var pr map[string]any
	res = s.do(t, http.MethodPost, "/api/repos/eugene/demo/pulls", map[string]any{"title": "Feature", "body": "fixes #1", "head": "feature", "base": "main"}, &pr)
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("pr %d", res.StatusCode)
	}
	number := int(pr["number"].(float64))
	res = s.do(t, http.MethodPost, "/api/repos/eugene/demo/pulls/"+itoa(number)+"/comments", map[string]any{
		"path": "README.md", "line": 1, "body": "ok\n```suggestion\n# Demo\n```\n",
	}, nil)
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("comment %d", res.StatusCode)
	}
	var merged map[string]any
	res = s.do(t, http.MethodPost, "/api/repos/eugene/demo/pulls/"+itoa(number)+"/merge", map[string]any{"method": "merge"}, &merged)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("merge %d %+v", res.StatusCode, merged)
	}
	var issues []map[string]any
	s.do(t, http.MethodGet, "/api/issues?q=is:closed", nil, &issues)
	if len(issues) != 1 || issues[0]["status"] != "done" {
		t.Fatalf("issues %+v", issues)
	}

	var squash map[string]any
	runGit(t, work, env, "checkout", "main")
	runGit(t, work, env, "pull")
	runGit(t, work, env, "checkout", "-b", "squash-me")
	os.WriteFile(filepath.Join(work, "squash.txt"), []byte("s\n"), 0o644)
	runGit(t, work, env, "add", "squash.txt")
	runGit(t, work, env, "commit", "-m", "squash this")
	runGit(t, work, env, "push", "origin", "HEAD:squash-me")
	s.do(t, http.MethodPost, "/api/repos/eugene/demo/pulls", map[string]any{"title": "Squash", "head": "squash-me", "base": "main"}, &squash)
	res = s.do(t, http.MethodPost, "/api/repos/eugene/demo/pulls/"+itoa(int(squash["number"].(float64)))+"/merge", map[string]any{"method": "squash"}, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("squash %d", res.StatusCode)
	}

	mirror := filepath.Join(t.TempDir(), "mirror.git")
	runGit(t, "", env, "init", "--bare", mirror)
	res = s.do(t, http.MethodPatch, "/api/repos/eugene/demo", map[string]any{"mirrorUrl": mirror, "mirrorMode": "push"}, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("mirror patch %d", res.StatusCode)
	}
	res = s.do(t, http.MethodPost, "/api/repos/eugene/demo/mirror/push", map[string]any{"ref": "refs/heads/main"}, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("mirror push %d", res.StatusCode)
	}
	if strings.TrimSpace(runGit(t, mirror, env, "rev-parse", "refs/heads/main")) == "" {
		t.Fatal("mirror missing main")
	}
	// Put an extra commit on the mirror, then require confirmation before force-push.
	extra := t.TempDir()
	runGit(t, "", env, "clone", mirror, extra)
	os.WriteFile(filepath.Join(extra, "lost.txt"), []byte("keep\n"), 0o644)
	runGit(t, extra, env, "add", "lost.txt")
	runGit(t, extra, env, "commit", "-m", "only on mirror")
	runGit(t, extra, env, "push")
	var denied map[string]any
	res = s.do(t, http.MethodPost, "/api/repos/eugene/demo/mirror/push", map[string]any{"ref": "refs/heads/main", "force": true}, &denied)
	if res.StatusCode != http.StatusConflict {
		t.Fatalf("force without confirm %d %+v", res.StatusCode, denied)
	}
	lost, _ := denied["lost"].([]any)
	if len(lost) != 1 {
		t.Fatalf("lost %+v", denied)
	}
	shaLost := lost[0].(map[string]any)["sha"].(string)
	res = s.do(t, http.MethodPost, "/api/repos/eugene/demo/mirror/push", map[string]any{
		"ref": "refs/heads/main", "force": true, "confirm": true, "lost": []string{shaLost},
	}, nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("confirmed force %d", res.StatusCode)
	}

	var bundles []map[string]any
	res = s.do(t, http.MethodPost, "/api/backups", map[string]any{}, &bundles)
	if res.StatusCode != http.StatusOK || len(bundles) == 0 {
		t.Fatalf("backup %d %+v", res.StatusCode, bundles)
	}
	runGit(t, "", env, "bundle", "verify", bundles[0]["path"].(string))

	var found map[string]any
	s.do(t, http.MethodGet, "/api/search?q=searchable", nil, &found)
	if code, _ := found["code"].([]any); len(code) == 0 {
		t.Fatalf("search %+v", found)
	}

	var release map[string]any
	res = s.do(t, http.MethodPost, "/api/repos/eugene/demo/releases", map[string]any{"tag": "v0.1.0", "fromCi": true}, &release)
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("release %d %+v", res.StatusCode, release)
	}
	assets, _ := release["assets"].([]any)
	if len(assets) == 0 {
		t.Fatalf("release assets %+v", release)
	}
}

func itoa(n int) string { return strconv.Itoa(n) }
