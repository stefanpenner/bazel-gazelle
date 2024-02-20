module github.com/bazelbuild/bazel-gazelle/tests/bcr/pkg

go 1.21.5

require (
	github.com/DataDog/sketches-go v1.4.4
	github.com/bazelbuild/buildtools v0.0.0-20240207142252-03bf520394af
	github.com/bazelbuild/rules_go v0.44.0
	github.com/bmatcuk/doublestar/v4 v4.6.1
	github.com/cloudflare/circl v1.3.7
	github.com/envoyproxy/protoc-gen-validate v1.0.4
	github.com/fmeum/dep_on_gazelle v1.0.0
	github.com/google/safetext v0.0.0-20240104143208-7a7d9b3d812f
	github.com/stretchr/testify v1.8.4
	golang.org/x/sys v0.17.0
)

require (
	github.com/bazelbuild/bazel-gazelle v0.30.0 // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/google/uuid v1.3.0 // indirect
	github.com/pborman/uuid v1.2.1 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	google.golang.org/protobuf v1.32.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

// Validate go.mod replace directives can be properly used:
replace github.com/bmatcuk/doublestar/v4 => github.com/bmatcuk/doublestar v1.3.4
