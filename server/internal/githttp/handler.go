// Package githttp serves the git smart HTTP protocol by executing
// upload-pack and receive-pack.
package githttp

import (
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/J3ckJ/EL-Workspace/server/internal/gitx"
	"github.com/J3ckJ/EL-Workspace/server/internal/names"
)

// Host resolves repositories and observes ref updates.
type Host struct {
	Git     gitx.Runner
	Path    func(owner, name string) (string, error)
	Changed func(owner, name string, changes []gitx.RefChange)
}

// ServeHTTP handles /git/{owner}/{name}.git/...
func (h Host) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	owner, name, tail, err := parsePath(r.URL.Path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	repo, err := h.Path(owner, name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	switch {
	case r.Method == http.MethodGet && tail == "info/refs":
		service := r.URL.Query().Get("service")
		h.advertise(w, repo, service)
	case r.Method == http.MethodPost && (tail == "git-upload-pack" || tail == "git-receive-pack"):
		h.rpc(w, r, repo, owner, name, tail)
	default:
		http.NotFound(w, r)
	}
}

func parsePath(p string) (owner, name, tail string, err error) {
	p = strings.TrimPrefix(p, "/")
	p = strings.TrimPrefix(p, "git/")
	parts := strings.SplitN(p, "/", 3)
	if len(parts) != 3 || !strings.HasSuffix(parts[1], ".git") {
		return "", "", "", fmt.Errorf("bad path")
	}
	owner = parts[0]
	name = strings.TrimSuffix(parts[1], ".git")
	if !names.Valid(owner) || !names.Valid(name) {
		return "", "", "", fmt.Errorf("bad name")
	}
	return owner, name, parts[2], nil
}

func (h Host) advertise(w http.ResponseWriter, repo, service string) {
	sub, err := gitSub(service)
	if err != nil {
		http.Error(w, "unsupported service", http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/x-"+service+"-advertisement")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(packetLine("# service=" + service + "\n"))
	_, _ = w.Write([]byte("0000"))
	var stderr strings.Builder
	err = h.Git.Stream(repo, nil, w, &stderr, sub, "--stateless-rpc", "--advertise-refs", ".")
	if err != nil {
		// Headers are already sent. The client will see a short advertisement.
		return
	}
}

func (h Host) rpc(w http.ResponseWriter, r *http.Request, repo, owner, name, service string) {
	sub, err := gitSub(service)
	if err != nil {
		http.Error(w, "unsupported service", http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/x-"+service+"-result")
	w.Header().Set("Cache-Control", "no-cache")
	var before map[string]string
	if service == "git-receive-pack" {
		before, _ = h.Git.Refs(repo)
	}
	var stderr strings.Builder
	body := io.LimitReader(r.Body, 512<<20)
	_ = h.Git.Stream(repo, body, w, &stderr, sub, "--stateless-rpc", ".")
	if service == "git-receive-pack" && h.Changed != nil {
		after, err := h.Git.Refs(repo)
		if err == nil {
			if changes := gitx.DiffRefs(before, after); len(changes) > 0 {
				h.Changed(owner, name, changes)
			}
		}
	}
}

func gitSub(service string) (string, error) {
	switch service {
	case "git-upload-pack":
		return "upload-pack", nil
	case "git-receive-pack":
		return "receive-pack", nil
	case "git-upload-archive":
		return "upload-archive", nil
	default:
		return "", fmt.Errorf("unsupported service")
	}
}

func packetLine(s string) []byte {
	n := len(s) + 4
	return []byte(fmt.Sprintf("%04x%s", n, s))
}
