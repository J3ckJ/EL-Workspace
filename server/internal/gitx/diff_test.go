package gitx

import "testing"

func TestParseDiff(t *testing.T) {
	const patch = `diff --git a/src/sim/cortege.ts b/src/sim/cortege.ts
index 111..222 100644
--- a/src/sim/cortege.ts
+++ b/src/sim/cortege.ts
@@ -1,3 +1,4 @@
 func spawn() {
-  let lead = left
+  let lead = innermost
+  lead.siren = true
 }
`
	files := ParseDiff(patch)
	if len(files) != 1 {
		t.Fatalf("files: %d", len(files))
	}
	file := files[0]
	if file.Path != "src/sim/cortege.ts" || file.Additions != 2 || file.Deletions != 1 {
		t.Fatalf("file %+v", file)
	}
	if len(file.Hunks) != 1 || len(file.Hunks[0].Lines) != 5 {
		t.Fatalf("hunks %+v", file.Hunks)
	}
}

func TestDiffRefs(t *testing.T) {
	before := map[string]string{"refs/heads/main": "aaa"}
	after := map[string]string{"refs/heads/main": "bbb", "refs/heads/topic": "ccc"}
	changes := DiffRefs(before, after)
	if len(changes) != 2 {
		t.Fatalf("changes %+v", changes)
	}
}
