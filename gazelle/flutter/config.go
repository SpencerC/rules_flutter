package flutter

import (
	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// Gazelle directives for Flutter
const (
	// DirectiveExclude excludes directories from Flutter rule generation
	DirectiveExclude = "flutter_exclude"

	// DirectiveLibraryName overrides the default "lib" name for flutter_library
	DirectiveLibraryName = "flutter_library_name"

	// DirectiveGenerate controls whether to generate flutter_library rules
	DirectiveGenerate = "flutter_generate"
)

// FlutterConfig contains Flutter-specific configuration
type FlutterConfig struct {
	// Exclude patterns for directories to skip
	Exclude []string

	// LibraryName override for flutter_library targets
	LibraryName string

	// Generate controls whether to generate flutter_library rules
	Generate bool
}

// GetFlutterConfig returns the FlutterConfig for a given config.Config
func GetFlutterConfig(c *config.Config) *FlutterConfig {
	if fc, ok := c.Exts["flutter"]; ok {
		return fc.(*FlutterConfig)
	}
	return &FlutterConfig{
		LibraryName: "lib",
		Generate:    true,
	}
}


// KnownDirectives returns the list of recognized Flutter directives
func (fc *FlutterConfig) KnownDirectives() []string {
	return []string{
		DirectiveExclude,
		DirectiveLibraryName,
		DirectiveGenerate,
	}
}

// Configure applies a directive to the configuration
func (fc *FlutterConfig) Configure(c *config.Config, rel string, f *rule.File) {
	if f == nil {
		return
	}

	// Process directives in the BUILD file
	for _, d := range f.Directives {
		switch d.Key {
		case DirectiveExclude:
			fc.Exclude = append(fc.Exclude, d.Value)
		case DirectiveLibraryName:
			fc.LibraryName = d.Value
		case DirectiveGenerate:
			fc.Generate = d.Value == "true" || d.Value == "yes" || d.Value == "1"
		}
	}
}

// Clone creates a copy of the configuration
func (fc *FlutterConfig) Clone() *FlutterConfig {
	return &FlutterConfig{
		Exclude:     append([]string{}, fc.Exclude...),
		LibraryName: fc.LibraryName,
		Generate:    fc.Generate,
	}
}

// IsExcluded checks if a directory should be excluded
func (fc *FlutterConfig) IsExcluded(dir string) bool {
	for _, pattern := range fc.Exclude {
		if pattern == dir {
			return true
		}
	}
	return false
}