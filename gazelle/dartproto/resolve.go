package dartproto

import (
	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/repo"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

func (pl *protoLang) Kinds() map[string]rule.KindInfo {
	return map[string]rule.KindInfo{
		"dart_proto_library": {
			MatchAny: false,
			NonEmptyAttrs: map[string]bool{
				"deps": true,
			},
			MergeableAttrs: map[string]bool{
				"deps":    true,
				"options": true,
			},
			ResolveAttrs: map[string]bool{
				"deps": true,
			},
		},
	}
}

func (pl *protoLang) Loads() []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_flutter//flutter:defs.bzl",
			Symbols: []string{"dart_proto_library"},
		},
	}
}

func (pl *protoLang) ApparentLoads(moduleToApparentName func(string) string) []rule.LoadInfo {
	return pl.Loads()
}

func (pl *protoLang) Imports(c *config.Config, r *rule.Rule, f *rule.File) []resolve.ImportSpec {
	return nil
}

func (pl *protoLang) Embeds(r *rule.Rule, from label.Label) []label.Label {
	return nil
}

func (pl *protoLang) Resolve(c *config.Config, ix *resolve.RuleIndex, rc *repo.RemoteCache, r *rule.Rule, imports interface{}, from label.Label) {
	// No additional dependency resolution required.
}
