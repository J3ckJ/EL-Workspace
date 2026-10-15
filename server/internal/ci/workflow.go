// Package ci parses a practical subset of GitHub Actions workflows and runs
// their `run` steps on the local machine.
package ci

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Workflow is the subset of a workflow file EL Workspace executes.
type Workflow struct {
	Name string
	Jobs []Job
	Push bool
	Pull bool
}

// Job is one job with shell steps.
type Job struct {
	ID     string
	Name   string
	RunsOn string
	Steps  []Step
}

// Step is either a local shell command or an unsupported action.
type Step struct {
	Name  string
	Run   string
	Uses  string
	Shell string
}

// JobResult is the outcome of one job.
type JobResult struct {
	Name   string `json:"name"`
	RunsOn string `json:"runsOn"`
	Status string `json:"status"`
	Log    string `json:"log"`
}

// Parse decodes a workflow file.
func Parse(data []byte) (Workflow, error) {
	var raw struct {
		Name string `yaml:"name"`
		On   any    `yaml:"on"`
		Jobs map[string]struct {
			Name   string `yaml:"name"`
			RunsOn any    `yaml:"runs-on"`
			Steps  []struct {
				Name  string `yaml:"name"`
				Run   string `yaml:"run"`
				Uses  string `yaml:"uses"`
				Shell string `yaml:"shell"`
			} `yaml:"steps"`
		} `yaml:"jobs"`
	}
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return Workflow{}, err
	}
	wf := Workflow{Name: raw.Name, Push: listens(raw.On, "push"), Pull: listens(raw.On, "pull_request")}
	for id, job := range raw.Jobs {
		item := Job{ID: id, Name: job.Name, RunsOn: runsOn(job.RunsOn)}
		if item.Name == "" {
			item.Name = id
		}
		for _, step := range job.Steps {
			item.Steps = append(item.Steps, Step{Name: step.Name, Run: step.Run, Uses: step.Uses, Shell: step.Shell})
		}
		wf.Jobs = append(wf.Jobs, item)
	}
	return wf, nil
}

func runsOn(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case []any:
		parts := make([]string, 0, len(t))
		for _, item := range t {
			parts = append(parts, fmt.Sprint(item))
		}
		return strings.Join(parts, ", ")
	default:
		if v == nil {
			return "self-hosted"
		}
		return fmt.Sprint(v)
	}
}

func listens(on any, event string) bool {
	switch t := on.(type) {
	case string:
		return t == event
	case []any:
		for _, item := range t {
			if fmt.Sprint(item) == event {
				return true
			}
		}
		return false
	case map[string]any:
		_, ok := t[event]
		return ok
	default:
		return false
	}
}

// Run executes every job in a checked-out workspace.
func Run(workspace, repoName, ref, sha string, wf Workflow, timeout time.Duration) (string, string, []JobResult) {
	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	var results []JobResult
	status := "success"
	var reason string
	for _, job := range wf.Jobs {
		res := runJob(workspace, repoName, ref, sha, job, timeout)
		results = append(results, res)
		if res.Status != "success" && status == "success" {
			status = "failure"
			reason = summarize(res.Log)
		}
	}
	if len(wf.Jobs) == 0 {
		status = "failure"
		reason = "В workflow нет jobs."
	}
	return status, reason, results
}

func runJob(workspace, repoName, ref, sha string, job Job, timeout time.Duration) JobResult {
	var log bytes.Buffer
	fmt.Fprintf(&log, "$ %s   runs-on: %s\n", job.Name, job.RunsOn)
	fmt.Fprintf(&log, "Локальный раннер %s · %s. Метки runs-on записываются в лог, команды выполняются на этой машине.\n", hostname(), runtime.GOOS)
	status := "success"
	for i, step := range job.Steps {
		name := step.Name
		if name == "" {
			name = fmt.Sprintf("step %d", i+1)
		}
		fmt.Fprintf(&log, "\n## %s\n", name)
		switch {
		case step.Uses != "" && isCheckout(step.Uses):
			fmt.Fprintf(&log, "actions/checkout — рабочая копия уже подготовлена (%s).\n", sha)
		case step.Uses != "":
			fmt.Fprintf(&log, "Пропущено: action %s не входит в локальный набор (поддерживаются шаги run: и actions/checkout).\n", step.Uses)
		case strings.TrimSpace(step.Run) == "":
			fmt.Fprintf(&log, "Пустой шаг.\n")
		default:
			fmt.Fprintf(&log, "%s\n", strings.TrimRight(step.Run, "\n"))
			out, err := runShell(workspace, repoName, ref, sha, step, timeout)
			log.Write(out)
			if err != nil {
				code := 1
				if exit, ok := err.(*exec.ExitError); ok {
					code = exit.ExitCode()
				}
				fmt.Fprintf(&log, "Process exited with code %d\n", code)
				status = "failure"
			}
		}
		if status == "failure" {
			break
		}
	}
	return JobResult{Name: job.Name, RunsOn: job.RunsOn, Status: status, Log: log.String()}
}

func isCheckout(uses string) bool {
	return strings.HasPrefix(uses, "actions/checkout@") || uses == "actions/checkout"
}

func runShell(workspace, repoName, ref, sha string, step Step, timeout time.Duration) ([]byte, error) {
	cmd := shellCommand(step.Shell, step.Run)
	cmd.Dir = workspace
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + workspace,
		"CI=true",
		"GITHUB_ACTIONS=true",
		"GITHUB_WORKSPACE=" + workspace,
		"GITHUB_SHA=" + sha,
		"GITHUB_REF=" + ref,
		"GITHUB_REPOSITORY=" + repoName,
		"EL_ARTIFACTS=" + filepath.Join(workspace, "artifacts"),
	}
	_ = os.MkdirAll(filepath.Join(workspace, "artifacts"), 0o755)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	timer := time.AfterFunc(timeout, func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	})
	defer timer.Stop()
	err := cmd.Run()
	return buf.Bytes(), err
}

func shellCommand(shell, script string) *exec.Cmd {
	switch shell {
	case "pwsh", "powershell":
		return exec.Command("pwsh", "-NoProfile", "-Command", script)
	case "sh":
		return exec.Command("sh", "-c", script)
	case "bash", "":
		if _, err := exec.LookPath("bash"); err == nil {
			return exec.Command("bash", "-lc", script)
		}
		return exec.Command("sh", "-c", script)
	default:
		return exec.Command("sh", "-c", script)
	}
}

func hostname() string {
	name, err := os.Hostname()
	if err != nil || name == "" {
		return "localhost"
	}
	return name
}

func summarize(log string) string {
	var picked []string
	for _, line := range strings.Split(log, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		lower := strings.ToLower(line)
		if strings.Contains(lower, "error") || strings.Contains(lower, "exited with code") || strings.HasPrefix(line, "error:") {
			picked = append(picked, line)
		}
	}
	if len(picked) == 0 {
		lines := strings.Split(strings.TrimSpace(log), "\n")
		if len(lines) > 4 {
			lines = lines[len(lines)-4:]
		}
		return strings.Join(lines, "\n")
	}
	if len(picked) > 6 {
		picked = picked[len(picked)-6:]
	}
	return strings.Join(picked, "\n")
}
