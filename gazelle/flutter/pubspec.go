package flutter

import (
	"encoding/json"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// PubDeps represents the structure of flutter pub deps --json output.
type PubDeps struct {
	Packages []PubDepsPackage `json:"packages"`
}

// PubDepsPackage represents a single package entry in pub_deps.json.
type PubDepsPackage struct {
	Name        string      `json:"name"`
	Dependency  string      `json:"dependency"`
	Description interface{} `json:"description"`
	Source      string      `json:"source"`
	Version     string      `json:"version"`
}

// PubspecYaml represents the structure of a pubspec.yaml file
type PubspecYaml struct {
	Name         string                 `yaml:"name"`
	Dependencies map[string]interface{} `yaml:"dependencies"`
	Environment  map[string]interface{} `yaml:"environment"`
}

// ParsePubDeps parses a pub_deps.json file and returns the parsed structure
func ParsePubDeps(path string) (*PubDeps, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var deps PubDeps
	if err := json.Unmarshal(data, &deps); err != nil {
		return nil, err
	}

	return &deps, nil
}

// ParsePubspecYaml parses a pubspec.yaml file and returns the parsed structure
func ParsePubspecYaml(path string) (*PubspecYaml, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var pubspec PubspecYaml
	if err := yaml.Unmarshal(data, &pubspec); err != nil {
		return nil, err
	}

	return &pubspec, nil
}

// GetDirectDependencies returns all direct dependencies from pub_deps.json.
// This includes main, dev, and overridden dependencies while still excluding transitives.
func GetDirectDependencies(depsFile *PubDeps) map[string]PubDepsPackage {
	deps := make(map[string]PubDepsPackage)

	if depsFile == nil {
		return deps
	}

	for _, pkg := range depsFile.Packages {
		name := pkg.Name
		if name == "" {
			continue
		}
		// Only include dependency entries that are marked as direct.
		if !strings.HasPrefix(pkg.Dependency, "direct") {
			continue
		}

		deps[name] = pkg
	}

	return deps
}

// SanitizeRepoName converts a package name to a valid Bazel repository name
// Matches the logic in flutter/extensions.bzl:_sanitize_repo_name
func SanitizeRepoName(pkg string) string {
	var result strings.Builder
	result.WriteString("pub_")

	for _, ch := range pkg {
		if (ch >= 'a' && ch <= 'z') ||
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '_' {
			result.WriteRune(ch)
		} else {
			result.WriteRune('_')
		}
	}

	return result.String()
}

// HasFlutterEnvironment checks if pubspec.yaml has environment.flutter set
func HasFlutterEnvironment(pubspec *PubspecYaml) bool {
	if pubspec == nil || pubspec.Environment == nil {
		return false
	}

	// Check if flutter key exists in environment
	_, hasFlutter := pubspec.Environment["flutter"]
	return hasFlutter
}

// HasSDKEnvironment checks if pubspec.yaml has environment.sdk set
func HasSDKEnvironment(pubspec *PubspecYaml) bool {
	if pubspec == nil || pubspec.Environment == nil {
		return false
	}

	// Check if sdk key exists in environment
	_, hasSDK := pubspec.Environment["sdk"]
	return hasSDK
}
