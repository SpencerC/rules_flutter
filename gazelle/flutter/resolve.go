package flutter

import (
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// Kinds returns the list of rule kinds that this language generates
func (fl *flutterLang) Kinds() map[string]rule.KindInfo {
	return map[string]rule.KindInfo{
		"flutter_library": {
			MatchAny: false,
			NonEmptyAttrs: map[string]bool{
				"pubspec": true,
			},
			MergeableAttrs: map[string]bool{
				"deps": true,
			},
			ResolveAttrs: map[string]bool{
				"deps": true,
			},
		},
		"flutter_app": {
			MatchAny: false,
			NonEmptyAttrs: map[string]bool{
				"embed": true,
			},
			MergeableAttrs: map[string]bool{
				"srcs": true,
			},
			ResolveAttrs: map[string]bool{
				"embed": true,
			},
		},
		"flutter_test": {
			MatchAny: false,
			NonEmptyAttrs: map[string]bool{
				"embed": true,
			},
			MergeableAttrs: map[string]bool{
				"srcs": true,
			},
			ResolveAttrs: map[string]bool{
				"embed": true,
			},
		},
		"dart_library": {
			MatchAny: false,
			NonEmptyAttrs: map[string]bool{
				"srcs": true,
			},
			MergeableAttrs: map[string]bool{
				"deps": true,
			},
			ResolveAttrs: map[string]bool{
				"deps": true,
			},
		},
	}
}

// Loads returns the Bazel load statements needed for Flutter rules
func (fl *flutterLang) Loads() []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_flutter//flutter:defs.bzl",
			Symbols: []string{"flutter_library", "flutter_app", "flutter_test", "dart_library"},
		},
	}
}

// resolveFlutterImport resolves a Dart package import to a Bazel label
func resolveFlutterImport(imp string) (label.Label, bool) {
	// Parse package: imports
	// Format: package:package_name/path/to/file.dart
	if !strings.HasPrefix(imp, "package:") {
		return label.Label{}, false
	}

	// Extract package name
	imp = strings.TrimPrefix(imp, "package:")
	parts := strings.SplitN(imp, "/", 2)
	if len(parts) == 0 {
		return label.Label{}, false
	}

	pkgName := parts[0]

	// Map to repository label
	repoName := SanitizeRepoName(pkgName)
	return label.New(repoName, "", pkgName), true
}

// Fix is not implemented for Flutter
func (fl *flutterLang) Fix(c *config.Config, f *rule.File) {
	// No automatic fixes needed
}

// ApparentLoads returns the load statements that are visible in the BUILD file
func (fl *flutterLang) ApparentLoads(moduleToApparentName func(string) string) []rule.LoadInfo {
	return fl.Loads()
}
