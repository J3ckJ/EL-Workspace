// Package gitssh is a small SSH server that accepts git-upload-pack and
// git-receive-pack from authorized keys.
package gitssh

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"

	"github.com/J3ckJ/EL-Workspace/server/internal/gitx"
	"github.com/J3ckJ/EL-Workspace/server/internal/names"
	"golang.org/x/crypto/ssh"
)

// Host is the git SSH endpoint.
type Host struct {
	Git     gitx.Runner
	Path    func(owner, name string) (string, error)
	Changed func(owner, name string, changes []gitx.RefChange)
	Allow   func(ssh.PublicKey) bool
}

// EnsureHostKey writes an ed25519 host key if the file is missing.
func EnsureHostKey(path string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	block, err := ssh.MarshalPrivateKey(priv, "el-workspace")
	if err != nil {
		return err
	}
	return os.WriteFile(path, pem.EncodeToMemory(block), 0o600)
}

// Listen starts the SSH server. The returned port is the bound port.
func (h Host) Listen(addr, keyPath string) (net.Listener, int, error) {
	raw, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, 0, err
	}
	signer, err := ssh.ParsePrivateKey(raw)
	if err != nil {
		return nil, 0, err
	}
	cfg := &ssh.ServerConfig{
		PublicKeyCallback: func(meta ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if h.Allow != nil && h.Allow(key) {
				return nil, nil
			}
			return nil, fmt.Errorf("unknown key")
		},
	}
	cfg.AddHostKey(signer)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, 0, err
	}
	return ln, ln.Addr().(*net.TCPAddr).Port, nil
}

// Serve accepts connections until the listener closes.
func (h Host) Serve(ln net.Listener, cfg *ssh.ServerConfig) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go h.serveConn(conn, cfg)
	}
}

// ServeListener builds the server config and serves.
func (h Host) ServeListener(ln net.Listener, keyPath string) error {
	raw, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	signer, err := ssh.ParsePrivateKey(raw)
	if err != nil {
		return err
	}
	cfg := &ssh.ServerConfig{
		PublicKeyCallback: func(meta ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if h.Allow != nil && h.Allow(key) {
				return nil, nil
			}
			return nil, fmt.Errorf("unknown key")
		},
	}
	cfg.AddHostKey(signer)
	h.Serve(ln, cfg)
	return nil
}

func (h Host) serveConn(conn net.Conn, cfg *ssh.ServerConfig) {
	defer conn.Close()
	sc, chans, reqs, err := ssh.NewServerConn(conn, cfg)
	if err != nil {
		return
	}
	defer sc.Close()
	go ssh.DiscardRequests(reqs)
	for ch := range chans {
		if ch.ChannelType() != "session" {
			_ = ch.Reject(ssh.UnknownChannelType, "only session")
			continue
		}
		channel, requests, err := ch.Accept()
		if err != nil {
			continue
		}
		go h.session(channel, requests)
	}
}

func (h Host) session(channel ssh.Channel, requests <-chan *ssh.Request) {
	defer channel.Close()
	for req := range requests {
		if req.Type != "exec" {
			_ = req.Reply(false, nil)
			continue
		}
		command, err := parseExec(req.Payload)
		if err != nil {
			_ = req.Reply(false, nil)
			return
		}
		service, owner, name, err := ParseCommand(command)
		if err != nil {
			_ = req.Reply(false, nil)
			_, _ = io.WriteString(channel.Stderr(), err.Error()+"\n")
			sendExit(channel, 128)
			return
		}
		repo, err := h.Path(owner, name)
		if err != nil {
			_ = req.Reply(false, nil)
			_, _ = io.WriteString(channel.Stderr(), "repository not found\n")
			sendExit(channel, 128)
			return
		}
		_ = req.Reply(true, nil)
		code := h.run(service, repo, owner, name, channel)
		sendExit(channel, code)
		return
	}
}

func (h Host) run(service, repo, owner, name string, channel ssh.Channel) int {
	sub, err := gitSub(service)
	if err != nil {
		return 128
	}
	var before map[string]string
	if service == "git-receive-pack" {
		before, _ = h.Git.Refs(repo)
	}
	err = h.Git.Stream(repo, channel, channel, channel.Stderr(), sub, ".")
	if service == "git-receive-pack" && h.Changed != nil {
		if after, refErr := h.Git.Refs(repo); refErr == nil {
			if changes := gitx.DiffRefs(before, after); len(changes) > 0 {
				h.Changed(owner, name, changes)
			}
		}
	}
	if err != nil {
		return 1
	}
	return 0
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
		return "", fmt.Errorf("unsupported")
	}
}

func parseExec(payload []byte) (string, error) {
	if len(payload) < 4 {
		return "", errors.New("short exec")
	}
	n := binary.BigEndian.Uint32(payload[:4])
	if int(n) > len(payload)-4 {
		return "", errors.New("bad exec")
	}
	return string(payload[4 : 4+n]), nil
}

func sendExit(channel ssh.Channel, code int) {
	var payload [4]byte
	binary.BigEndian.PutUint32(payload[:], uint32(code))
	_, _ = channel.SendRequest("exit-status", false, payload[:])
}

// ParseCommand extracts the git service and owner/name from an SSH exec line.
func ParseCommand(command string) (service, owner, name string, err error) {
	parts, err := splitShell(strings.TrimSpace(command))
	if err != nil || len(parts) != 2 {
		return "", "", "", errors.New("только git-upload-pack и git-receive-pack")
	}
	switch parts[0] {
	case "git-upload-pack", "git-receive-pack", "git-upload-archive":
	default:
		return "", "", "", errors.New("команда не разрешена")
	}
	repo := strings.TrimPrefix(parts[1], "/")
	repo = strings.TrimSuffix(repo, ".git")
	segs := strings.Split(repo, "/")
	if len(segs) != 2 || !names.Valid(segs[0]) || !names.Valid(segs[1]) {
		return "", "", "", errors.New("неизвестный репозиторий")
	}
	return parts[0], segs[0], segs[1], nil
}

func splitShell(s string) ([]string, error) {
	var out []string
	var b strings.Builder
	var quote rune
	for _, r := range s {
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
				continue
			}
			b.WriteRune(r)
		case r == '\'' || r == '"':
			quote = r
		case r == ' ' || r == '\t':
			if b.Len() > 0 {
				out = append(out, b.String())
				b.Reset()
			}
		default:
			b.WriteRune(r)
		}
	}
	if quote != 0 {
		return nil, errors.New("кавычка не закрыта")
	}
	if b.Len() > 0 {
		out = append(out, b.String())
	}
	return out, nil
}
