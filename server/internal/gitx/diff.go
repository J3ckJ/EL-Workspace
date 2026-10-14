package gitx

import (
	"regexp"
	"strconv"
	"strings"
)

// Line is one row of a unified diff.
type Line struct {
	Kind string `json:"kind"`
	Old  int    `json:"old,omitempty"`
	New  int    `json:"new,omitempty"`
	Text string `json:"text"`
}

// Hunk is a contiguous @@ block.
type Hunk struct {
	OldStart int    `json:"oldStart"`
	NewStart int    `json:"newStart"`
	Lines    []Line `json:"lines"`
}

// FileDiff is one file inside a patch.
type FileDiff struct {
	Path      string `json:"path"`
	OldPath   string `json:"oldPath,omitempty"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
	Binary    bool   `json:"binary"`
	Hunks     []Hunk `json:"hunks"`
}

var hunkRe = regexp.MustCompile(`^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@`)

// ParseDiff converts unified diff text into structured files.
func ParseDiff(text string) []FileDiff {
	var files []FileDiff
	var cur *FileDiff
	var hunk *Hunk
	oldLine, newLine := 0, 0
	flushHunk := func() {
		if cur != nil && hunk != nil {
			cur.Hunks = append(cur.Hunks, *hunk)
			hunk = nil
		}
	}
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "diff --git ") {
			flushHunk()
			if cur != nil {
				files = append(files, *cur)
			}
			cur = &FileDiff{Path: pathFromGit(line)}
			continue
		}
		if cur == nil {
			continue
		}
		switch {
		case strings.HasPrefix(line, "Binary files "):
			cur.Binary = true
		case strings.HasPrefix(line, "rename from "):
			cur.OldPath = strings.TrimPrefix(line, "rename from ")
		case strings.HasPrefix(line, "rename to "):
			cur.Path = strings.TrimPrefix(line, "rename to ")
		case strings.HasPrefix(line, "--- "):
			p := strings.TrimPrefix(line, "--- ")
			p = strings.TrimPrefix(p, "a/")
			if p != "/dev/null" && cur.Path == "" {
				cur.Path = p
			}
			if p != "/dev/null" {
				cur.OldPath = p
			}
		case strings.HasPrefix(line, "+++ "):
			p := strings.TrimPrefix(line, "+++ ")
			p = strings.TrimPrefix(p, "b/")
			if p != "/dev/null" {
				cur.Path = p
			}
		case strings.HasPrefix(line, "@@"):
			flushHunk()
			m := hunkRe.FindStringSubmatch(line)
			h := Hunk{}
			if len(m) >= 4 {
				h.OldStart, _ = strconv.Atoi(m[1])
				h.NewStart, _ = strconv.Atoi(m[3])
			}
			hunk = &h
			oldLine = h.OldStart
			newLine = h.NewStart
		case strings.HasPrefix(line, `\ `):
			continue
		case hunk != nil && strings.HasPrefix(line, "+"):
			hunk.Lines = append(hunk.Lines, Line{Kind: "add", New: newLine, Text: line[1:]})
			cur.Additions++
			newLine++
		case hunk != nil && strings.HasPrefix(line, "-"):
			hunk.Lines = append(hunk.Lines, Line{Kind: "del", Old: oldLine, Text: line[1:]})
			cur.Deletions++
			oldLine++
		case hunk != nil && (strings.HasPrefix(line, " ") || line == ""):
			if line == "" {
				continue
			}
			hunk.Lines = append(hunk.Lines, Line{Kind: "ctx", Old: oldLine, New: newLine, Text: line[1:]})
			oldLine++
			newLine++
		}
	}
	flushHunk()
	if cur != nil {
		files = append(files, *cur)
	}
	return files
}

func pathFromGit(line string) string {
	const mark = " b/"
	if i := strings.LastIndex(line, mark); i >= 0 {
		return strings.Trim(line[i+len(mark):], `"`)
	}
	return ""
}
