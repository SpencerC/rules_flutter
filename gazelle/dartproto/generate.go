package dartproto

import (
	"sort"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"

	"github.com/spencerconnaughton/rules_flutter/gazelle/flutter"
)

// GenerateRules emits dart_proto_library targets for proto_library rules that already exist.
func (pl *protoLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	fc := flutter.GetFlutterConfig(args.Config)
	if !fc.Generate || fc.IsExcluded(args.Rel) {
		return language.GenerateResult{}
	}

	protoNames := collectProtoLibraries(args)
	if len(protoNames) == 0 {
		return language.GenerateResult{}
	}

	existingDart := collectExistingDartProtoLibraries(args)

	var names []string
	for name := range protoNames {
		dartName := name + "_dart"
		if existingDart[dartName] {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)

	if len(names) == 0 {
		return language.GenerateResult{}
	}

	gen := make([]*rule.Rule, 0, len(names))
	imports := make([]interface{}, 0, len(names))
	for _, name := range names {
		dartName := name + "_dart"
		r := rule.NewRule("dart_proto_library", dartName)
		r.SetAttr("deps", []string{":" + name})
		gen = append(gen, r)
		imports = append(imports, []resolve.ImportSpec{})
	}

	return language.GenerateResult{
		Gen:     gen,
		Imports: imports,
	}
}

func collectProtoLibraries(args language.GenerateArgs) map[string]bool {
	result := make(map[string]bool)

	for _, r := range args.OtherGen {
		if r.Kind() == "proto_library" {
			result[r.Name()] = true
		}
	}

	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Kind() == "proto_library" {
				result[r.Name()] = true
			}
		}
	}

	return result
}

func collectExistingDartProtoLibraries(args language.GenerateArgs) map[string]bool {
	result := make(map[string]bool)

	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Kind() == "dart_proto_library" {
				result[r.Name()] = true
			}
		}
	}

	for _, r := range args.OtherGen {
		if r.Kind() == "dart_proto_library" {
			result[r.Name()] = true
		}
	}

	return result
}

func (pl *protoLang) Fix(c *config.Config, f *rule.File) {
	// No automatic fixes required.
}
