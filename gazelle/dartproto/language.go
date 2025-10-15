package dartproto

import (
	"flag"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const languageName = "dartproto"

type protoLang struct{}

// NewLanguage returns a new Gazelle language for Dart proto generation.
func NewLanguage() language.Language {
	return &protoLang{}
}

func (pl *protoLang) Name() string {
	return languageName
}

func (pl *protoLang) RegisterFlags(fs *flag.FlagSet, cmd string, c *config.Config) {
	// No-op: configuration is shared with the flutter language.
}

func (pl *protoLang) CheckFlags(fs *flag.FlagSet, c *config.Config) error {
	return nil
}

func (pl *protoLang) KnownDirectives() []string {
	return nil
}

func (pl *protoLang) Configure(c *config.Config, rel string, f *rule.File) {
	// No-op: defer to the flutter language for configuration handling.
}
