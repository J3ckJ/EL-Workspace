package ci

import "testing"

func TestParseTriggers(t *testing.T) {
	wf, err := Parse([]byte("name: sample\non: [push, pull_request]\njobs:\n  test:\n    runs-on: self-hosted\n    steps:\n      - run: echo EL_CI_OK\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !wf.Push || !wf.Pull || len(wf.Jobs) != 1 || wf.Jobs[0].Steps[0].Run == "" {
		t.Fatalf("%+v", wf)
	}
	status, reason, jobs := Run(t.TempDir(), "eugene/sample", "refs/heads/main", "abc", wf, 0)
	if status != "success" || len(jobs) != 1 {
		t.Fatalf("%s %s %+v", status, reason, jobs)
	}
}
