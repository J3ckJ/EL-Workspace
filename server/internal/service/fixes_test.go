package service

import (
	"testing"
	"time"
)

func TestIssueNumbersClosedBy(t *testing.T) {
	cases := []struct {
		text string
		want []int
	}{
		{"fixes #12", []int{12}},
		{"fix: сокеты #12", []int{12}},
		{"This mentions #4 only", nil},
		{"Closes #2 and fixes #3", []int{2, 3}},
	}
	for _, tc := range cases {
		got := IssueNumbersClosedBy(tc.text)
		if len(got) != len(tc.want) {
			t.Fatalf("%q => %v", tc.text, got)
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Fatalf("%q => %v", tc.text, got)
			}
		}
	}
}

func TestDueBackup(t *testing.T) {
	loc := time.UTC
	now := time.Date(2026, 10, 14, 3, 5, 0, 0, loc)
	if !DueBackup(now, "03:00", time.Time{}) {
		t.Fatal("first backup of the day should be due")
	}
	if DueBackup(now, "03:00", now.Add(-time.Minute)) {
		t.Fatal("backup already ran after the scheduled time")
	}
	early := time.Date(2026, 10, 14, 2, 0, 0, 0, loc)
	if DueBackup(early, "03:00", time.Time{}) {
		t.Fatal("before the scheduled minute")
	}
}

func TestValidStatusSwitch(t *testing.T) {
	for _, status := range []string{"backlog", "progress", "review", "done"} {
		if !ValidIssueStatus(status) {
			t.Fatal(status)
		}
	}
	if ValidIssueStatus("archived") || ValidMirrorMode("force") {
		t.Fatal("unknown values must be rejected")
	}
}
