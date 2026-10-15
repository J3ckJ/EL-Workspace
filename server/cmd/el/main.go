package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/J3ckJ/EL-Workspace/server/internal/api"
	"github.com/J3ckJ/EL-Workspace/server/internal/config"
	"github.com/J3ckJ/EL-Workspace/server/internal/demo"
	"github.com/J3ckJ/EL-Workspace/server/internal/githttp"
	"github.com/J3ckJ/EL-Workspace/server/internal/gitssh"
	"github.com/J3ckJ/EL-Workspace/server/internal/gitx"
	"github.com/J3ckJ/EL-Workspace/server/internal/service"
	"github.com/J3ckJ/EL-Workspace/server/internal/store"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "serve":
		os.Exit(cmdServe(os.Args[2:]))
	case "repo":
		os.Exit(cmdRepo(os.Args[2:]))
	case "pr":
		os.Exit(cmdPR(os.Args[2:]))
	case "release":
		os.Exit(cmdRelease(os.Args[2:]))
	case "key":
		os.Exit(cmdKey(os.Args[2:]))
	case "panel":
		os.Exit(cmdPanel(os.Args[2:]))
	case "status":
		os.Exit(cmdStatus())
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "Неизвестная команда %q\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `EL Workspace — локальный Git-хост

  el serve [--data DIR] [--http ADDR] [--ssh ADDR] [--demo] [--open]
  el repo create <name> [--description TEXT]
  el pr checkout <n> [--repo owner/name]
  el release <tag> --from-ci [--repo owner/name] [--publish]
  el key add <file.pub> [--title TEXT]
  el panel
  el status

`)
}

func cmdServe(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	data := fs.String("data", "", "каталог данных")
	httpAddr := fs.String("http", "127.0.0.1:8080", "адрес HTTP")
	sshAddr := fs.String("ssh", "127.0.0.1:2222", "адрес SSH")
	demoMode := fs.Bool("demo", false, "заполнить демонстрационными репозиториями")
	openBrowser := fs.Bool("open", false, "открыть интерфейс в браузере")
	host := fs.String("host", "", "имя хоста в URL клонирования")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	dir := *data
	var err error
	if dir == "" {
		dir, err = config.DefaultDataDir()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	if err := config.Prepare(dir); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	st, err := store.Open(filepath.Join(dir, "state.db"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer st.Close()
	svc := service.New(dir, st, gitx.Runner{Env: config.GitEnv(dir)})
	if *host != "" {
		svc.AdvertiseHost = *host
	} else if saved := st.Setting("advertise_host", ""); saved != "" {
		svc.AdvertiseHost = saved
	}
	svc.ImportDefaultKey()
	if *demoMode {
		if err := demo.Seed(svc); err != nil {
			fmt.Fprintln(os.Stderr, "демо:", err)
			return 1
		}
	}
	sshLn, err := net.Listen("tcp", *sshAddr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "SSH:", err)
		return 1
	}
	httpLn, err := net.Listen("tcp", *httpAddr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "HTTP:", err)
		return 1
	}
	svc.HTTPAddr = httpLn.Addr().String()
	svc.SSHPort = sshLn.Addr().(*net.TCPAddr).Port
	keyPath := filepath.Join(dir, "ssh", "host_ed25519")
	if err := gitssh.EnsureHostKey(keyPath); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	sshHost := gitssh.Host{Git: svc.Git, Path: svc.Resolve, Changed: svc.HandleRefs, Allow: svc.AllowKey}
	go func() { _ = sshHost.ServeListener(sshLn, keyPath) }()
	git := githttp.Host{Git: svc.Git, Path: svc.Resolve, Changed: svc.HandleRefs}
	app := &api.Server{Svc: svc, HostKey: keyPath}
	svc.Start()
	endpoint := map[string]any{"http": "http://" + svc.HTTPAddr, "ssh": svc.SSHPort, "pid": os.Getpid()}
	raw, _ := json.MarshalIndent(endpoint, "", "  ")
	_ = os.WriteFile(filepath.Join(dir, "server.json"), raw, 0o644)
	defer func() { _ = os.Remove(filepath.Join(dir, "server.json")) }()
	fmt.Printf("EL Workspace  http://%s\n", svc.HTTPAddr)
	fmt.Printf("SSH           порт %d\n", svc.SSHPort)
	fmt.Printf("Данные        %s\n", dir)
	if *openBrowser {
		_ = openURL("http://" + svc.HTTPAddr)
	}
	errCh := make(chan error, 1)
	go func() { errCh <- http.Serve(httpLn, app.Handler(git)) }()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-sig:
		svc.Stop()
		_ = httpLn.Close()
		_ = sshLn.Close()
		return 0
	case err := <-errCh:
		if err != nil && !strings.Contains(err.Error(), "use of closed") {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		return 0
	}
}

func cmdRepo(args []string) int {
	if len(args) < 2 || args[0] != "create" {
		fmt.Fprintln(os.Stderr, "Использование: el repo create <name>")
		return 2
	}
	fs := flag.NewFlagSet("repo", flag.ContinueOnError)
	desc := fs.String("description", "", "описание")
	data := fs.String("data", "", "каталог данных")
	_ = fs.Parse(args[2:])
	base, err := client(*data)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var out map[string]any
	if err := base.post("/api/repos", map[string]any{"name": args[1], "description": *desc}, &out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(out["http"])
	fmt.Println(out["ssh"])
	return 0
}

func cmdPR(args []string) int {
	if len(args) < 2 || args[0] != "checkout" {
		fmt.Fprintln(os.Stderr, "Использование: el pr checkout <n> --repo owner/name")
		return 2
	}
	n := args[1]
	fs := flag.NewFlagSet("pr", flag.ContinueOnError)
	repo := fs.String("repo", "", "owner/name")
	data := fs.String("data", "", "каталог данных")
	_ = fs.Parse(args[2:])
	identity := *repo
	if identity == "" {
		identity = repoFromCwd()
	}
	if identity == "" {
		fmt.Fprintln(os.Stderr, "Укажите --repo owner/name")
		return 2
	}
	base, err := client(*data)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var info map[string]any
	if err := base.get("/api/repos/"+identity+"/checkout/"+n, &info); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	branch, _ := info["branch"].(string)
	httpURL, _ := info["http"].(string)
	if _, err := os.Stat(".git"); err == nil {
		if err := run("git", "fetch", httpURL, branch); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		if err := run("git", "checkout", branch); err != nil {
			if err := run("git", "checkout", "-b", branch, "FETCH_HEAD"); err != nil {
				fmt.Fprintln(os.Stderr, err)
				return 1
			}
		}
		fmt.Println(branch)
		return 0
	}
	name := identity
	if i := strings.LastIndex(identity, "/"); i >= 0 {
		name = identity[i+1:]
	}
	if err := run("git", "clone", "--branch", branch, httpURL, name); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(name)
	return 0
}

func cmdRelease(args []string) int {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "Использование: el release <tag> --from-ci --repo owner/name")
		return 2
	}
	tag := args[0]
	fs := flag.NewFlagSet("release", flag.ContinueOnError)
	repo := fs.String("repo", "", "owner/name")
	fromCI := fs.Bool("from-ci", false, "взять файлы последней зелёной сборки")
	publish := fs.Bool("publish", false, "отправить тег на зеркало")
	data := fs.String("data", "", "каталог данных")
	_ = fs.Parse(args[1:])
	identity := *repo
	if identity == "" {
		identity = repoFromCwd()
	}
	if identity == "" {
		fmt.Fprintln(os.Stderr, "Укажите --repo owner/name")
		return 2
	}
	base, err := client(*data)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var out map[string]any
	body := map[string]any{"tag": tag, "fromCi": *fromCI, "publish": *publish}
	if err := base.post("/api/repos/"+identity+"/releases", body, &out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(tag)
	return 0
}

func cmdKey(args []string) int {
	if len(args) < 2 || args[0] != "add" {
		fmt.Fprintln(os.Stderr, "Использование: el key add <file.pub>")
		return 2
	}
	fs := flag.NewFlagSet("key", flag.ContinueOnError)
	title := fs.String("title", "ключ", "название")
	data := fs.String("data", "", "каталог данных")
	_ = fs.Parse(args[2:])
	raw, err := os.ReadFile(args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	base, err := client(*data)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := base.post("/api/keys", map[string]any{"title": *title, "key": string(raw)}, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println("ключ добавлен")
	return 0
}

func cmdPanel(args []string) int {
	fs := flag.NewFlagSet("panel", flag.ContinueOnError)
	data := fs.String("data", "", "каталог данных")
	openIt := fs.Bool("open", true, "открыть панель")
	_ = fs.Parse(args)
	base, err := client(*data)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var panel map[string]any
	if err := base.get("/api/panel", &panel); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(panel)
	if *openIt {
		_ = openURL(base.origin + "/#/panel")
	}
	return 0
}

func cmdStatus() int {
	base, err := client("")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var meta map[string]any
	if err := base.get("/api/meta", &meta); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(base.origin)
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(meta)
	return 0
}

type httpClient struct {
	origin string
	http   *http.Client
}

func client(data string) (*httpClient, error) {
	dir := data
	var err error
	if dir == "" {
		dir, err = config.DefaultDataDir()
		if err != nil {
			return nil, err
		}
	}
	raw, err := os.ReadFile(filepath.Join(dir, "server.json"))
	if err != nil {
		return nil, fmt.Errorf("сервер не запущен, выполните el serve")
	}
	var info struct {
		HTTP string `json:"http"`
	}
	if err := json.Unmarshal(raw, &info); err != nil {
		return nil, err
	}
	return &httpClient{origin: strings.TrimRight(info.HTTP, "/"), http: &http.Client{Timeout: 60 * time.Second}}, nil
}

func (c *httpClient) get(path string, dest any) error {
	res, err := c.http.Get(c.origin + path)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	return decode(res, dest)
}

func (c *httpClient) post(path string, body any, dest any) error {
	raw, _ := json.Marshal(body)
	res, err := c.http.Post(c.origin+path, "application/json", strings.NewReader(string(raw)))
	if err != nil {
		return err
	}
	defer res.Body.Close()
	return decode(res, dest)
}

func decode(res *http.Response, dest any) error {
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if res.StatusCode >= 300 {
		var payload struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &payload)
		if payload.Error == "" {
			payload.Error = strings.TrimSpace(string(raw))
		}
		return fmt.Errorf("%s", payload.Error)
	}
	if dest == nil || len(raw) == 0 {
		return nil
	}
	return json.Unmarshal(raw, dest)
}

func repoFromCwd() string {
	out, err := exec.Command("git", "remote", "get-url", "origin").Output()
	if err != nil {
		return ""
	}
	text := strings.TrimSpace(string(out))
	text = strings.TrimSuffix(text, ".git")
	if i := strings.LastIndex(text, "/"); i >= 0 {
		name := text[i+1:]
		rest := text[:i]
		if j := strings.LastIndex(rest, "/"); j >= 0 {
			return rest[j+1:] + "/" + name
		}
	}
	return ""
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func openURL(raw string) error {
	switch {
	case commandExists("xdg-open"):
		return exec.Command("xdg-open", raw).Start()
	case commandExists("open"):
		return exec.Command("open", raw).Start()
	case commandExists("cmd"):
		return exec.Command("cmd", "/c", "start", raw).Start()
	default:
		fmt.Println(raw)
		return nil
	}
}

func commandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
