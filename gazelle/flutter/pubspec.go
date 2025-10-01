package flutter

import (
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// PubspecLock represents the structure of a pubspec.lock file
type PubspecLock struct {
	Packages map[string]PubPackage `yaml:"packages"`
}

// PubPackage represents a single package entry in pubspec.lock
type PubPackage struct {
	Dependency  string      `yaml:"dependency"`
	Description interface{} `yaml:"description"`
	Source      string      `yaml:"source"`
	Version     string      `yaml:"version"`
}

// PubspecYaml represents the structure of a pubspec.yaml file
type PubspecYaml struct {
	Name         string                 `yaml:"name"`
	Dependencies map[string]interface{} `yaml:"dependencies"`
	Environment  map[string]interface{} `yaml:"environment"`
}

// ParsePubspecLock parses a pubspec.lock file and returns the parsed structure
func ParsePubspecLock(path string) (*PubspecLock, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var lock PubspecLock
	if err := yaml.Unmarshal(data, &lock); err != nil {
		return nil, err
	}

	return &lock, nil
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

// GetDirectDependencies returns all direct dependencies from pubspec.lock.
// This includes main, dev, and overridden dependencies while still excluding transitives.
func GetDirectDependencies(lock *PubspecLock) map[string]PubPackage {
	deps := make(map[string]PubPackage)

	for name, pkg := range lock.Packages {
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
