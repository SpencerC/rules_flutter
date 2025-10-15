package dartproto

import (
	"reflect"
	"testing"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"

	"github.com/spencerconnaughton/rules_flutter/gazelle/flutter"
)

func TestGenerateRulesProducesProtoTargets(t *testing.T) {
	pl := &protoLang{}
	cfg := &config.Config{Exts: map[string]interface{}{}}
	cfg.Exts["flutter"] = &flutter.FlutterConfig{
		LibraryName: "lib",
		Generate:    true,
		SDKRepo:     "@flutter_sdk",
	}

	args := language.GenerateArgs{
		Config: cfg,
		Dir:    ".",
		Rel:    "services/api/v1",
		OtherGen: []*rule.Rule{
			rule.NewRule("proto_library", "services_api_v1_proto"),
		},
	}

	result := pl.GenerateRules(args)
	if len(result.Gen) != 1 {
		t.Fatalf("GenerateRules: expected 1 rule, got %d", len(result.Gen))
	}

	if kind := result.Gen[0].Kind(); kind != "dart_proto_library" {
		t.Fatalf("generated rule kind: want dart_proto_library, got %s", kind)
	}
	if name := result.Gen[0].Name(); name != "services_api_v1_proto_dart" {
		t.Fatalf("dart_proto_library name: want services_api_v1_proto_dart, got %s", name)
	}
	if deps := result.Gen[0].AttrStrings("deps"); !reflect.DeepEqual(deps, []string{":services_api_v1_proto"}) {
		t.Fatalf("dart_proto_library deps: want [:services_api_v1_proto], got %v", deps)
	}
}
