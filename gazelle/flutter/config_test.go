package flutter

import (
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
)

func TestDefaultSDKRepoIsApparentName(t *testing.T) {
	// The generated BUILD files must reference the SDK by its apparent name,
	// which resolves via repo mapping in any consuming module. The canonical
	// name (owned by rules_flutter's extension, not the module being gazelled)
	// must never be emitted, regardless of the current module's RepoName.
	for _, repoName := range []string{"", "gazelle_app", "ggx"} {
		c := &config.Config{RepoName: repoName}
		if got := defaultSDKRepo(c); got != "@flutter_sdk" {
			t.Fatalf("defaultSDKRepo(RepoName=%q) = %q, want %q", repoName, got, "@flutter_sdk")
		}
	}
}

func TestSDKRepoDirectiveOverrides(t *testing.T) {
	fc := &FlutterConfig{SDKRepo: "@flutter_sdk"}
	if got := sdkDependencyLabel("flutter", fc); got != "@flutter_sdk//flutter/packages/flutter:flutter" {
		t.Fatalf("unexpected sdk label before override: %q", got)
	}

	// An explicit, non-empty flutter_sdk_repo directive wins.
	fc.SDKRepo = "@my_flutter"
	if got := sdkDependencyLabel("flutter", fc); got != "@my_flutter//flutter/packages/flutter:flutter" {
		t.Fatalf("directive override not applied: %q", got)
	}
}
