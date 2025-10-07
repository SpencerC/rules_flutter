package flutter

import (
	"reflect"
	"testing"
)

func TestGenerateDepsIncludesAllDirectDependencies(t *testing.T) {
	lock := &PubspecLock{
		Packages: map[string]PubPackage{
			"vector_math": {
				Dependency: "direct main",
				Source:     "hosted",
			},
			"flutter_test": {
				Dependency: "direct dev",
				Source:     "sdk",
			},
			"flutter": {
				Dependency: "direct main",
				Source:     "sdk",
			},
			"flutter_lints": {
				Dependency: "direct dev",
				Source:     "hosted",
			},
			"collection": {
				Dependency: "transitive",
				Source:     "hosted",
			},
		},
	}

	fc := &FlutterConfig{SDKRepo: "@flutter_macos"}
	got := generateDeps(lock, fc)
	want := []string{
		"@flutter_macos//flutter/packages/flutter:flutter",
		"@flutter_macos//flutter/packages/flutter_test:flutter_test",
		"@pub_flutter_lints//:flutter_lints",
		"@pub_vector_math//:vector_math",
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("generateDeps(...):\nwant %v\n got %v", want, got)
	}
}

func TestGetDirectDependenciesIncludesAllDirectKinds(t *testing.T) {
	lock := &PubspecLock{
		Packages: map[string]PubPackage{
			"direct-main": {
				Dependency: "direct main",
			},
			"direct-dev": {
				Dependency: "direct dev",
			},
			"direct-overridden": {
				Dependency: "direct overridden",
			},
			"transitive": {
				Dependency: "transitive",
			},
		},
	}

	got := GetDirectDependencies(lock)
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
	fc := &FlutterConfig{SDKRepo: "@flutter_macos"}
	got := sdkDependencyLabel("flutter", fc)
	want := "@flutter_macos//flutter/packages/flutter:flutter"

	if got != want {
		t.Fatalf("sdkDependencyLabel(...): want %q got %q", want, got)
	}
}

func TestSDKDependencyLabelSkyEngine(t *testing.T) {
	fc := &FlutterConfig{SDKRepo: "@flutter_linux"}
	got := sdkDependencyLabel("sky_engine", fc)
	want := "@flutter_linux//flutter/bin/cache/pkg/sky_engine:sky_engine"

	if got != want {
		t.Fatalf("sdkDependencyLabel(...): want %q got %q", want, got)
	}
}
