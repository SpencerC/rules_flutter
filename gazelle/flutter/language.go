// Package flutter provides Gazelle language support for Flutter projects
package flutter

import (
	"flag"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const languageName = "flutter"

type flutterLang struct{}

// NewLanguage returns a new Flutter language extension for Gazelle
func NewLanguage() language.Language {
	return &flutterLang{}
}

// Name returns the name of this language extension
func (fl *flutterLang) Name() string {
	return languageName
}

// RegisterFlags registers command-line flags for Flutter
func (fl *flutterLang) RegisterFlags(fs *flag.FlagSet, cmd string, c *config.Config) {
	fc := &FlutterConfig{
		LibraryName: "lib",
		Generate:    true,
	}
	c.Exts[languageName] = fc
}

// CheckFlags validates the Flutter configuration
func (fl *flutterLang) CheckFlags(fs *flag.FlagSet, c *config.Config) error {
	return nil
}

// KnownDirectives returns the list of directives recognized by this language
func (fl *flutterLang) KnownDirectives() []string {
	fc := &FlutterConfig{}
	return fc.KnownDirectives()
}

// Configure applies configuration from a BUILD file
func (fl *flutterLang) Configure(c *config.Config, rel string, f *rule.File) {
	// Clone the parent config
	var fc *FlutterConfig
	if parentFC := GetFlutterConfig(c); parentFC != nil {
		fc = parentFC.Clone()
	} else {
		fc = &FlutterConfig{
			LibraryName: "lib",
			Generate:    true,
		}
	}

	// Apply directives from the BUILD file if present
	if f != nil {
		fc.Configure(c, rel, f)
	}

	c.Exts[languageName] = fc
}