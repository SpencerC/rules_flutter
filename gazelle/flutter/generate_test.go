package flutter

import (
	"reflect"
	"testing"
)

func TestGenerateDepsIncludesAllDirectDependencies(t *testing.T) {
	deps := &PubDeps{
		Packages: []PubDepsPackage{
			{Name: "vector_math", Dependency: "direct main", Source: "hosted"},
			{Name: "flutter_test", Dependency: "direct dev", Source: "sdk"},
			{Name: "flutter", Dependency: "direct main", Source: "sdk"},
			{Name: "flutter_lints", Dependency: "direct dev", Source: "hosted"},
			{Name: "collection", Dependency: "transitive", Source: "hosted"},
		},
	}

	fc := &FlutterConfig{SDKRepo: "@flutter_sdk"}
	got := generateDeps(deps, fc)
	want := []string{
		"@flutter_sdk//flutter/packages/flutter:flutter",
		"@flutter_sdk//flutter/packages/flutter_test:flutter_test",
		"@pub_flutter_lints//:flutter_lints",
		"@pub_vector_math//:vector_math",
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("generateDeps(...):\nwant %v\n got %v", want, got)
	}
}

func TestGetDirectDependenciesIncludesAllDirectKinds(t *testing.T) {
	deps := &PubDeps{
		Packages: []PubDepsPackage{
			{Name: "direct-main", Dependency: "direct main"},
			{Name: "direct-dev", Dependency: "direct dev"},
			{Name: "direct-overridden", Dependency: "direct overridden"},
			{Name: "transitive", Dependency: "transitive"},
		},
	}

	got := GetDirectDependencies(deps)
	if len(got) != 3 {
		t.Fatalf("expected 3 direct dependencies, got %d", len(got))
	}

	for _, name := range []string{"direct-main", "direct-dev", "direct-overridden"} {
		if _, ok := got[name]; !ok {
			t.Fatalf("expected dependency %q to be returned", name)
		}
	}

	if _, ok := got["transitive"]; ok {
		t.Fatalf("did not expect transitive dependencies to be included")
	}
}

func TestSDKDependencyLabelDefaultPackage(t *testing.T) {
	fc := &FlutterConfig{SDKRepo: "@flutter_sdk"}
	got := sdkDependencyLabel("flutter", fc)
	want := "@flutter_sdk//flutter/packages/flutter:flutter"

	if got != want {
		t.Fatalf("sdkDependencyLabel(...): want %q got %q", want, got)
	}
}

func TestSDKDependencyLabelSkyEngine(t *testing.T) {
	fc := &FlutterConfig{SDKRepo: "@flutter_sdk"}
	got := sdkDependencyLabel("sky_engine", fc)
	want := "@flutter_sdk//flutter/bin/cache/pkg/sky_engine:sky_engine"

	if got != want {
		t.Fatalf("sdkDependencyLabel(...): want %q got %q", want, got)
	}
}
