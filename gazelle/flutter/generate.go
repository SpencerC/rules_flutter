package flutter

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/repo"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// GenerateRules generates Flutter build rules for a directory
func (fl *flutterLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	fc := GetFlutterConfig(args.Config)

	// Skip if generation is disabled
	if !fc.Generate {
		return language.GenerateResult{}
	}

	// Skip if directory is excluded
	if fc.IsExcluded(args.Rel) {
		return language.GenerateResult{}
	}

	// Check if pubspec.yaml exists in this directory
	hasPubspec := false
	for _, f := range args.RegularFiles {
		if f == "pubspec.yaml" {
			hasPubspec = true
			break
		}
	}

	if !hasPubspec {
		return language.GenerateResult{}
	}

	// Check if pubspec.lock exists (for dependencies)
	hasPubspecLock := false
	var pubspecLock *PubspecLock
	for _, f := range args.RegularFiles {
		if f == "pubspec.lock" {
			hasPubspecLock = true
			lockPath := filepath.Join(args.Dir, f)
			lock, err := ParsePubspecLock(lockPath)
			if err == nil {
				pubspecLock = lock
			}
			break
		}
	}

	// Check if lib/ directory exists
	hasLib := false
	for _, d := range args.Subdirs {
		if d == "lib" {
			hasLib = true
			break
		}
	}

	// Generate flutter_library rule
	r := rule.NewRule("flutter_library", fc.LibraryName)

	// Set pubspec attribute
	r.SetAttr("pubspec", "pubspec.yaml")

	// Set srcs attribute - only include lib/**
	if hasLib {
		srcs := []string{"lib/**"}
		r.SetAttr("srcs", generateGlob(srcs))
	}

	// Set deps attribute from pubspec.lock if available
	if hasPubspecLock && pubspecLock != nil {
		deps := generateDeps(pubspecLock)
		if len(deps) > 0 {
			r.SetAttr("deps", deps)
		}
	}

	return language.GenerateResult{
		Gen:     []*rule.Rule{r},
		Imports: []interface{}{},  // No imports needed for now
	}
}

// generateGlob creates a glob() expression for srcs
func generateGlob(patterns []string) interface{} {
	// Return a special marker that will be formatted as glob([...]) in the output
	return rule.GlobValue{
		Patterns: patterns,
	}
}

// generateDeps creates a list of dependency labels from pubspec.lock
func generateDeps(lock *PubspecLock) []string {
	directDeps := GetDirectDependencies(lock)
	if len(directDeps) == 0 {
		return nil
	}

	deps := make([]string, 0, len(directDeps))
	for pkg := range directDeps {
		repoName := SanitizeRepoName(pkg)
		// Generate label like @pub_fixnum//:fixnum
		dep := fmt.Sprintf("@%s//:%s", repoName, pkg)
		deps = append(deps, dep)
	}

	// Sort for consistent output
	sortStrings(deps)
	return deps
}

// sortStrings sorts a slice of strings in place
func sortStrings(s []string) {
	// Simple bubble sort for small lists
	n := len(s)
	for i := 0; i < n-1; i++ {
		for j := 0; j < n-i-1; j++ {
			if s[j] > s[j+1] {
				s[j], s[j+1] = s[j+1], s[j]
			}
		}
	}
}

// Imports extracts import statements from Flutter/Dart source files
func (fl *flutterLang) Imports(c *config.Config, r *rule.Rule, f *rule.File) []resolve.ImportSpec {
	// For now, we don't need to parse Dart imports
	// The dependencies are extracted from pubspec.lock
	return nil
}

// Embeds is not used for Flutter
func (fl *flutterLang) Embeds(r *rule.Rule, from label.Label) []label.Label {
	return nil
}

// Resolve resolves imports to labels
func (fl *flutterLang) Resolve(c *config.Config, ix *resolve.RuleIndex, rc *repo.RemoteCache, r *rule.Rule, importsRaw interface{}, from label.Label) {
	// Dependencies are already resolved in GenerateRules
	// This is called after generation to finalize labels
}

// parseImports parses Dart import statements from source code
// Returns a list of import paths
func parseImports(content string) []string {
	var imports []string

	lines := strings.Split(content, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)

		// Look for import statements: import 'package:...' or import "package:..."
		if strings.HasPrefix(line, "import ") {
			// Extract the quoted string
			start := strings.Index(line, "'")
			if start == -1 {
				start = strings.Index(line, "\"")
			}
			if start == -1 {
				continue
			}

			quote := line[start]
			end := strings.Index(line[start+1:], string(quote))
			if end == -1 {
				continue
			}

			importPath := line[start+1 : start+1+end]

			// Only include package: imports
			if strings.HasPrefix(importPath, "package:") {
				imports = append(imports, importPath)
			}
		}
	}

	return imports
}