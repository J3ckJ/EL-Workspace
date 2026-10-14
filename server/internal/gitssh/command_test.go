package gitssh

import "testing"

func TestParseCommand(t *testing.T) {
	service, owner, name, err := ParseCommand("git-upload-pack '/eugene/FlyDrop.git'")
	if err != nil || service != "git-upload-pack" || owner != "eugene" || name != "FlyDrop" {
		t.Fatalf("%s %s %s %v", service, owner, name, err)
	}
	if _, _, _, err := ParseCommand("bash -c id"); err == nil {
		t.Fatal("shell must be rejected")
	}
	if _, _, _, err := ParseCommand("git-upload-pack '/eugene/../secret.git'"); err == nil {
		t.Fatal("traversal must be rejected")
	}
}
