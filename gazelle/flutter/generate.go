package flutter

import (
	"fmt"
	"os"
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

	if !fc.Generate || fc.IsExcluded(args.Rel) {
		return language.GenerateResult{}
	}

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

	hasPubDeps := false
	var pubDeps *PubDeps
	for _, f := range args.RegularFiles {
		if f == "pub_deps.json" {
			hasPubDeps = true
			depsPath := filepath.Join(args.Dir, f)
			deps, err := ParsePubDeps(depsPath)
			if err == nil {
				pubDeps = deps
			}
			break
		}
	}

	hasLib := false
	for _, d := range args.Subdirs {
		if d == "lib" {
			hasLib = true
			break
		}
	}

	pubspecYamlPath := filepath.Join(args.Dir, "pubspec.yaml")
	pubspecYaml, err := ParsePubspecYaml(pubspecYamlPath)
	if err != nil {
		pubspecYaml = nil
	}

	ruleKind := "flutter_library"
	if pubspecYaml != nil {
		hasFlutter := HasFlutterEnvironment(pubspecYaml)
		hasSDK := HasSDKEnvironment(pubspecYaml)

		if !hasFlutter && hasSDK {
			ruleKind = "dart_library"
		}
	}

	r := rule.NewRule(ruleKind, fc.LibraryName)
	r.SetAttr("pubspec", "pubspec.yaml")

	if hasLib {
		srcs := collectSourceFiles(args.Dir, hasLib)
		if len(srcs) > 0 {
			r.SetAttr("srcs", srcs)
		}
	}

	if hasPubDeps && pubDeps != nil {
		deps := generateDeps(pubDeps, fc)
		if len(deps) > 0 {
			r.SetAttr("deps", deps)
		}
	}

	// Must return same number of imports as rules (1)
	imports := []interface{}{[]resolve.ImportSpec{}}

	return language.GenerateResult{
		Gen:     []*rule.Rule{r},
		Imports: imports,
	}
}

// collectSourceFiles walks the lib/ directory and returns all source files
func collectSourceFiles(baseDir string, hasLib bool) []string {
	var srcs []string

	if hasLib {
		libFiles := walkDir(filepath.Join(baseDir, "lib"), baseDir)
		srcs = append(srcs, libFiles...)
	}

	// Sort for consistent output
	sortStrings(srcs)
	return srcs
}

// walkDir recursively walks a directory and returns relative paths to all files
func walkDir(dir string, baseDir string) []string {
	var files []string

	filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // Skip errors
		}
		if !info.IsDir() {
			// Get relative path from baseDir
			relPath, err := filepath.Rel(baseDir, path)
			if err == nil {
				files = append(files, relPath)
			}
		}
		return nil
	})

	return files
}

// generateDeps creates a list of dependency labels from pub_deps.json
func generateDeps(depsFile *PubDeps, fc *FlutterConfig) []string {
	directDeps := GetDirectDependencies(depsFile)
	if len(directDeps) == 0 {
		return nil
	}

	deps := make([]string, 0, len(directDeps))
	for pkg, meta := range directDeps {
		depKind := meta.Dependency
		if !strings.HasPrefix(depKind, "direct") {
			continue
		}

		switch meta.Source {
		case "hosted":
			repoName := SanitizeRepoName(pkg)
			deps = append(deps, fmt.Sprintf("@%s//:%s", repoName, pkg))
		case "sdk":
			if sdkLabel := sdkDependencyLabel(pkg, fc); sdkLabel != "" {
				deps = append(deps, sdkLabel)
			}
		}
	}

	// Sort for consistent output
	sortStrings(deps)
	return deps
}

// sdkDependencyLabel returns the Bazel label for an SDK provided package.
func sdkDependencyLabel(pkg string, fc *FlutterConfig) string {
	if fc == nil || fc.SDKRepo == "" {
		return ""
	}

	path := sdkPackagePath(pkg)
	if path == "" {
		return ""
	}

	return fmt.Sprintf("%s//%s:%s", fc.SDKRepo, path, pkg)
}

// sdkPackagePath returns the repository relative path for an SDK package target.
func sdkPackagePath(pkg string) string {
	switch pkg {
	case "sky_engine":
		return fmt.Sprintf("flutter/bin/cache/pkg/%s", pkg)
	default:
		return fmt.Sprintf("flutter/packages/%s", pkg)
	}
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
	// The dependencies are extracted from pub_deps.json
	return []resolve.ImportSpec{}
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
