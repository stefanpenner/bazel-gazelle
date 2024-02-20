# Copyright 2023 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("//internal:go_repository.bzl", "go_repository")
load(":go_mod.bzl", "deps_from_go_mod", "parse_go_work", "sums_from_go_mod", "sums_from_go_work")
load(
    ":default_gazelle_overrides.bzl",
    "DEFAULT_BUILD_EXTRA_ARGS_BY_PATH",
    "DEFAULT_BUILD_FILE_GENERATION_BY_PATH",
    "DEFAULT_DIRECTIVES_BY_PATH",
)
load(":semver.bzl", "humanize_comparable_version", "semver")
load(
    ":utils.bzl",
    "drop_nones",
    "format_rule_call",
    "get_directive_value",
    "with_replaced_or_new_fields",
)

visibility("//")

_HIGHEST_VERSION_SENTINEL = semver.to_comparable("999999.999999.999999")

_FORBIDDEN_OVERRIDE_TAG = """\
Using the "go_deps.{tag_class}" tag in a non-root Bazel module is forbidden, \
but module "{module_name}" requests it.

If you need this override for a Bazel module that will be available in a public \
registry (such as the Bazel Central Registry), please file an issue at \
https://github.com/bazelbuild/bazel-gazelle/issues/new or submit a PR adding \
the required directives to the "default_gazelle_overrides.bzl" file at \
https://github.com/bazelbuild/bazel-gazelle/tree/master/internal/bzlmod/default_gazelle_overrides.bzl.
"""

def go_work_from_label(module_ctx, go_work_label):
    """Loads deps from a go.work file"""
    go_work_path = module_ctx.path(go_work_label)
    go_work_content = module_ctx.read(go_work_path)
    return parse_go_work(go_work_content, go_work_label)

def _fail_on_non_root_overrides(module_ctx, module, tag_class):
    if module.is_root:
        return

    # Isolated module extension usages only contain tags from a single module, so we can allow
    # overrides. This is a new feature in Bazel 6.3.0, earlier versions do not allow module usages
    # to be isolated.
    if getattr(module_ctx, "is_isolated", False):
        return

    if getattr(module.tags, tag_class):
        fail(_FORBIDDEN_OVERRIDE_TAG.format(
            tag_class = tag_class,
            module_name = module.name,
        ))

def _fail_on_duplicate_overrides(path, module_name, overrides):
    if path in overrides:
        fail("Multiple overrides defined for Go module path \"{}\" in module \"{}\".".format(path, module_name))

def _fail_on_unmatched_overrides(override_keys, resolutions, override_name):
    unmatched_overrides = [path for path in override_keys if path not in resolutions]
    if unmatched_overrides:
        fail("Some {} did not target a Go module with a matching path: {}".format(
            override_name,
            ", ".join(unmatched_overrides),
        ))

def _check_directive(directive):
    if directive.startswith("gazelle:") and " " in directive and not directive[len("gazelle:"):][0].isspace():
        return
    fail("Invalid Gazelle directive: \"{}\". Gazelle directives must be of the form \"gazelle:key value\".".format(directive))

def _get_build_file_generation(path, gazelle_overrides):
    override = gazelle_overrides.get(path)
    if override:
        return override.build_file_generation

    return DEFAULT_BUILD_FILE_GENERATION_BY_PATH.get(path, "auto")

def _get_build_extra_args(path, gazelle_overrides):
    override = gazelle_overrides.get(path)
    if override:
        return override.build_extra_args
    return DEFAULT_BUILD_EXTRA_ARGS_BY_PATH.get(path, [])

def _get_directives(path, gazelle_overrides):
    override = gazelle_overrides.get(path)
    if override:
        return override.directives

    return DEFAULT_DIRECTIVES_BY_PATH.get(path, [])

def _get_patches(path, module_overrides):
    override = module_overrides.get(path)
    if override:
        return override.patches
    return []

def _get_patch_args(path, module_overrides):
    override = module_overrides.get(path)
    if override:
        return ["-p{}".format(override.patch_strip)]
    return []

def _repo_name(importpath):
    path_segments = importpath.split("/")
    segments = reversed(path_segments[0].split(".")) + path_segments[1:]
    candidate_name = "_".join(segments).replace("-", "_")
    return "".join([c.lower() if c.isalnum() else "_" for c in candidate_name.elems()])

def _is_dev_dependency(module_ctx, tag):
    if hasattr(tag, "_is_dev_dependency"):
        # Synthetic tags generated from go_deps.from_file have this "hidden" attribute.
        return tag._is_dev_dependency

    # This function is available in Bazel 6.2.0 and later. This is the same version that has
    # module_ctx.extension_metadata, so the return value of this function is not used if it is
    # not available.
    return module_ctx.is_dev_dependency(tag) if hasattr(module_ctx, "is_dev_dependency") else False

# This function processes a given override type for a given module, checks for duplicate overrides
# and inserts the override returned from the process_override_func into the overrides dict.
def _process_overrides(module_ctx, module, override_type, overrides, process_override_func, additional_overrides = None):
    _fail_on_non_root_overrides(module_ctx, module, override_type)
    for override_tag in getattr(module.tags, override_type):
        _fail_on_duplicate_overrides(override_tag.path, module.name, overrides)

        # Some overrides conflict with other overrides. These can be specified in the
        # additional_overrides dict. If the override is in the additional_overrides dict, then fail.
        if additional_overrides:
            _fail_on_duplicate_overrides(override_tag.path, module.name, additional_overrides)

        overrides[override_tag.path] = process_override_func(override_tag)

def _process_gazelle_override(gazelle_override_tag):
    for directive in gazelle_override_tag.directives:
        _check_directive(directive)

    return struct(
        directives = gazelle_override_tag.directives,
        build_file_generation = gazelle_override_tag.build_file_generation,
        build_extra_args = gazelle_override_tag.build_extra_args,
    )

def _process_module_override(module_override_tag):
    return struct(
        patches = module_override_tag.patches,
        patch_strip = module_override_tag.patch_strip,
    )

def _process_archive_override(archive_override_tag):
    return struct(
        urls = archive_override_tag.urls,
        sha256 = archive_override_tag.sha256,
        strip_prefix = archive_override_tag.strip_prefix,
        patches = archive_override_tag.patches,
        patch_strip = archive_override_tag.patch_strip,
    )

def _extension_metadata(module_ctx, *, root_module_direct_deps, root_module_direct_dev_deps):
    if not hasattr(module_ctx, "extension_metadata"):
        return None
    return module_ctx.extension_metadata(
        root_module_direct_deps = root_module_direct_deps,
        root_module_direct_dev_deps = root_module_direct_dev_deps,
    )

def _go_repository_config_impl(ctx):
    repos = []
    for name, importpath in sorted(ctx.attr.importpaths.items()):
        repos.append(format_rule_call(
            "go_repository",
            name = name,
            importpath = importpath,
            module_name = ctx.attr.module_names.get(name),
            build_naming_convention = ctx.attr.build_naming_conventions.get(name),
        ))

    ctx.file("WORKSPACE", "\n".join(repos))
    ctx.file("BUILD.bazel", "exports_files(['WORKSPACE'])")

_go_repository_config = repository_rule(
    implementation = _go_repository_config_impl,
    attrs = {
        "importpaths": attr.string_dict(mandatory = True),
        "module_names": attr.string_dict(mandatory = True),
        "build_naming_conventions": attr.string_dict(mandatory = True),
    },
)

def fail_on_version_conflict(version, previous, module_tag, module_name_to_go_dot_mod_label, go_works, fail_or_warn):
    """
    Check if duplicate modules have different versions, and fail with a useful error message if they do.

    Args:
        version: The version of the module.
        previous: The previous module object.
        module_tag: The module tag.
        module_name_to_go_dot_mod_label: A dictionary mapping module paths to go.mod labels.
        go_works: A list of go_work objects representing use statements in the go.work file.
        previous: The previous module object.
    """

    if not previous:
        # no previous module, so no possible error
        return

    if not previous or version == previous.version:
        # version is the same, skip because we won't error
        return

    # When using go.work, duplicate dependency versions are possible.
    # This can cause issues, so we fail with a hopefully actionable error.
    current_label = module_tag.parent_label

    previous_label = previous.module_tag.parent_label

    corrective_measure = None
    default_corrective_mesasure = "To correct this:\n 1. manually update: all go.mod files to ensure the versions of '{}' are the same.\n 2. in the folder where you made changes to run: go mod tidy\n 3. run: go work sync.".format(module_tag.path)

    if previous.version[0] == version[0] or str(current_label).endswith("go.work") or str(previous_label).endswith("go.work"):
        corrective_measure = default_corrective_mesasure
    else:
        label = module_name_to_go_dot_mod_label.get(module_tag.path)

        print(dir(previous.module_tag))
        if label:
            # if the label is present that means the module_tag is of a go.mod file, which means the correct action may be different.

            # if the duplicate module in question is provided by go.work use statement then only manual intervention can fix it
            # from_file_tags on go_work represents use statements in the go.work file
            for from_file_tags in [go_work.from_file_tags for go_work in go_works]:
                for from_file_tag in from_file_tags:
                    if from_file_tag.go_mod == label:
                        corrective_measure = default_corrective_mesasure
                        break
        elif previous.module_tag.indirect or module_tag.indirect:
            # if the dependency indirect, the user will need to manually update go.mod, run go mod tidy in that directory and then run go work sync
            corrective_measure = default_corrective_mesasure
        else:
            # TODO: if the version are v0.8.0 and v0.17.0 go work sync wont work
            # ensure the corrective measure describes this. Maybe this is limited to indirect dependencies
            corrective_measure = "To correct this, run:\n 1. go work sync."

    message = "Multiple versions of {} found:\n - {} contains: {}\n - {} contains {}.\n{}".format(module_tag.path, current_label, humanize_comparable_version(version), previous_label, humanize_comparable_version(previous.version), corrective_measure)

    if fail_or_warn:
        fail(message)
    else:
        print(message)

def _fail_if_not_root(module, from_file_tag):
    if module.is_root != True:
        fail("go_deps.from_file(go_work = '{}') tag can only be used from a root module but: '{}' is not a root module.".format(from_file_tag.go_work, module.name))

def _fail_if_invalid_from_file_usage(from_file_tag):
    if (
        (from_file_tag.go_work == None and from_file_tag.go_mod == None) and
        (from_file_tag.go_work != None and from_file_tag.go_mod != None)
    ):
        fail("go_deps.from_file tag must have either go_work or go_mod attribute, but not both.")

def _noop(_):
    pass

# These repos are shared between the isolated and non-isolated instances of go_deps as they are
# referenced directly by rules (go_proto_library) and would result in linker errors due to duplicate
# packages if they were resolved separately.
# When adding a new Go module to this list, make sure that:
# 1. The corresponding repository is visible to the gazelle module via a use_repo directive.
# 2. All transitive dependencies of the module are also in this list. Avoid adding module that have
#    a large number of transitive dependencies.
_SHARED_REPOS = [
    "github.com/golang/protobuf",
    "google.golang.org/protobuf",
]

def _go_deps_impl(module_ctx):
    module_resolutions = {}
    sums = {}
    replace_map = {}
    bazel_deps = {}

    archive_overrides = {}
    gazelle_overrides = {}
    module_overrides = {}

    root_versions = {}
    root_module_direct_deps = {}
    root_module_direct_dev_deps = {}

    if module_ctx.modules[0].name == "gazelle":
        root_module_direct_deps["bazel_gazelle_go_repository_config"] = None

    outdated_direct_dep_printer = print
    for module in module_ctx.modules:
        # Parse the go_deps.config tag of the root module only.
        for mod_config in module.tags.config:
            if not module.is_root:
                continue
            check_direct_deps = mod_config.check_direct_dependencies
            if check_direct_deps == "off":
                outdated_direct_dep_printer = _noop
            elif check_direct_deps == "warning":
                outdated_direct_dep_printer = print
            elif check_direct_deps == "error":
                outdated_direct_dep_printer = fail

        _process_overrides(module_ctx, module, "gazelle_override", gazelle_overrides, _process_gazelle_override)
        _process_overrides(module_ctx, module, "module_override", module_overrides, _process_module_override, archive_overrides)
        _process_overrides(module_ctx, module, "archive_override", archive_overrides, _process_archive_override, module_overrides)

        if len(module.tags.from_file) > 1:
            fail(
                "Multiple \"go_deps.from_file\" tags defined in module \"{}\": {}".format(
                    module.name,
                    ", ".join([str(tag.go_mod) for tag in module.tags.from_file]),
                ),
            )

        additional_module_tags = []
        from_file_tags = []
        go_works = []
        module_name_to_go_dot_mod_label = {}

        for from_file_tag in module.tags.from_file:
            _fail_if_invalid_from_file_usage(from_file_tag)

            if from_file_tag.go_mod:
                from_file_tags.append(from_file_tag)
            elif from_file_tag.go_work:
                _fail_if_not_root(module, from_file_tag)

                go_work = go_work_from_label(module_ctx, from_file_tag.go_work)
                go_works.append(go_work)

                # this ensures go.work replacements as considered
                additional_module_tags += [
                    with_replaced_or_new_fields(tag, _is_dev_dependency = False)
                    for tag in go_work.module_tags
                ]

                for entry, new_sum in sums_from_go_work(module_ctx, from_file_tag.go_work).items():
                    _safe_insert_sum(sums, entry, new_sum)

                replace_map.update(go_work.replace_map)
                from_file_tags = from_file_tags + go_work.from_file_tags
            else:
                fail("Either \"go_mod\" or \"go_work\" must be specified in \"go_deps.from_file\" tags.")

        for from_file_tag in from_file_tags:
            module_path, module_tags_from_go_mod, go_mod_replace_map, module_name = deps_from_go_mod(module_ctx, from_file_tag.go_mod)
            module_name_to_go_dot_mod_label[module_name] = from_file_tag.go_mod
            is_dev_dependency = _is_dev_dependency(module_ctx, from_file_tag)
            additional_module_tags += [
                with_replaced_or_new_fields(tag, _is_dev_dependency = is_dev_dependency)
                for tag in module_tags_from_go_mod
            ]

            if module.is_root or getattr(module_ctx, "is_isolated", False):
                replace_map.update(go_mod_replace_map)
            else:
                # Register this Bazel module as providing the specified Go module. It participates
                # in version resolution using its registry version, which uses a relaxed variant of
                # semver that can however still be compared to strict semvers.
                # An empty version string signals an override, which is assumed to be newer than any
                # other version.
                raw_version = _canonicalize_raw_version(module.version)
                version = semver.to_comparable(raw_version, relaxed = True) if raw_version else _HIGHEST_VERSION_SENTINEL
                if module_path not in bazel_deps or version > bazel_deps[module_path].version:
                    bazel_deps[module_path] = struct(
                        module_name = module.name,
                        repo_name = "@" + from_file_tag.go_mod.workspace_name,
                        version = version,
                        raw_version = raw_version,
                    )

            # Load all sums from transitively resolved `go.sum` files that have modules.
            if len(module_tags_from_go_mod) > 0:
                for entry, new_sum in sums_from_go_mod(module_ctx, from_file_tag.go_mod).items():
                    _safe_insert_sum(sums, entry, new_sum)

        # Load sums from manually specified modules separately.
        for module_tag in module.tags.module:
            if module_tag.build_naming_convention:
                fail("""The "build_naming_convention" attribute is no longer supported for "go_deps.module" tags. Use a "gazelle:go_naming_convention" directive via the "gazelle_override" tag's "directives" attribute instead.""")
            if module_tag.build_file_proto_mode:
                fail("""The "build_file_proto_mode" attribute is no longer supported for "go_deps.module" tags. Use a "gazelle:proto" directive via the "gazelle_override" tag's "directives" attribute instead.""")
            sum_version = _canonicalize_raw_version(module_tag.version)
            _safe_insert_sum(sums, (module_tag.path, sum_version), module_tag.sum)

        # Parse the go_dep.module tags of all transitive dependencies and apply
        # Minimum Version Selection to resolve importpaths to Go module versions
        # and sums.
        #
        # Note: This applies Minimum Version Selection on the resolved
        # dependency graphs of all transitive Bazel module dependencies, which
        # is not what `go mod` does. But since this algorithm ends up using only
        # Go module versions that have been explicitly declared somewhere in the
        # full graph, we can assume that at that place all its required
        # transitive dependencies have also been declared - we may end up
        # resolving them to higher versions, but only compatible ones.
        paths = {}

        for module_tag in module.tags.module + additional_module_tags:
            if not module_tag.path in paths:
                paths[module_tag.path] = None
            if module_tag.path in bazel_deps:
                continue
            raw_version = _canonicalize_raw_version(module_tag.version)

            # For modules imported from a go.sum, we know which ones are direct
            # dependencies and can thus only report implicit version upgrades
            # for direct dependencies. For manually specified go_deps.module
            # tags, we always report version upgrades unless users override with
            # the "indirect" attribute.
            if module.is_root and not module_tag.indirect:
                root_versions[module_tag.path] = raw_version
                if _is_dev_dependency(module_ctx, module_tag):
                    root_module_direct_dev_deps[_repo_name(module_tag.path)] = None
                else:
                    root_module_direct_deps[_repo_name(module_tag.path)] = None

            version = semver.to_comparable(raw_version)
            previous = paths.get(module_tag.path)

            fail_or_warn = len([x for x in module.tags.from_file if x.fail_on_version_conflict == True]) > 0

            # rather then failing, we could do MVS here, or some other heuristic
            fail_on_version_conflict(version, previous, module_tag, module_name_to_go_dot_mod_label, go_works, fail_or_warn)
            paths[module_tag.path] = struct(version = version, module_tag = module_tag)

            if module_tag.path not in module_resolutions or version > module_resolutions[module_tag.path].version:
                module_resolutions[module_tag.path] = struct(
                    repo_name = _repo_name(module_tag.path),
                    version = version,
                    raw_version = raw_version,
                )

    _fail_on_unmatched_overrides(archive_overrides.keys(), module_resolutions, "archive_overrides")
    _fail_on_unmatched_overrides(gazelle_overrides.keys(), module_resolutions, "gazelle_overrides")
    _fail_on_unmatched_overrides(module_overrides.keys(), module_resolutions, "module_overrides")

    # All `replace` directives are applied after version resolution.
    # We can simply do this by checking the replace paths' existence
    # in the module resolutions and swapping out the entry.
    for path, replace in replace_map.items():
        if path in module_resolutions:
            # If the replace directive specified a version then we only
            # apply it if the versions match.
            if replace.from_version:
                comparable_from_version = semver.to_comparable(replace.from_version)
                if module_resolutions[path].version != comparable_from_version:
                    continue

            new_version = semver.to_comparable(replace.version)
            module_resolutions[path] = with_replaced_or_new_fields(
                module_resolutions[path],
                replace = replace.to_path,
                version = new_version,
                raw_version = replace.version,
            )
            if path in root_versions:
                if replace != replace.to_path:
                    # If the root module replaces a Go module with a completely different one, do
                    # not ever report an implicit version upgrade.
                    root_versions.pop(path)
                else:
                    root_versions[path] = replace.version

    for path, bazel_dep in bazel_deps.items():
        # We can't apply overrides to Bazel dependencies and thus fall back to using the Go module.
        if path in archive_overrides or path in gazelle_overrides or path in module_overrides or path in replace_map:
            continue

        # Only use the Bazel module if it is at least as high as the required Go module version.
        if path in module_resolutions and bazel_dep.version < module_resolutions[path].version:
            outdated_direct_dep_printer(
                "Go module \"{path}\" is provided by Bazel module \"{bazel_module}\" in version {bazel_dep_version}, but requested at higher version {go_version} via Go requirements. Consider adding or updating an appropriate \"bazel_dep\" to ensure that the Bazel module is used to provide the Go module.".format(
                    path = path,
                    bazel_module = bazel_dep.module_name,
                    bazel_dep_version = bazel_dep.raw_version,
                    go_version = module_resolutions[path].raw_version,
                ),
            )
            continue

        # TODO: We should update root_versions if the bazel_dep is a direct dependency of the root
        #   module. However, we currently don't have a way to determine that.
        module_resolutions[path] = bazel_dep

    for path, root_version in root_versions.items():
        if semver.to_comparable(root_version) < module_resolutions[path].version:
            outdated_direct_dep_printer(
                "For Go module \"{path}\", the root module requires module version v{root_version}, but got v{resolved_version} in the resolved dependency graph.".format(
                    path = path,
                    root_version = root_version,
                    resolved_version = module_resolutions[path].raw_version,
                ),
            )

    for path, module in module_resolutions.items():
        if hasattr(module, "module_name"):
            # Do not create a go_repository for a Go module provided by a bazel_dep.
            root_module_direct_deps.pop(_repo_name(path), default = None)
            root_module_direct_dev_deps.pop(_repo_name(path), default = None)
            continue
        if getattr(module_ctx, "is_isolated", False) and path in _SHARED_REPOS:
            # Do not create a go_repository for a dep shared with the non-isolated instance of
            # go_deps.
            continue

        go_repository_args = {
            "name": module.repo_name,
            "importpath": path,
            "build_directives": _get_directives(path, gazelle_overrides),
            "build_file_generation": _get_build_file_generation(path, gazelle_overrides),
            "build_extra_args": _get_build_extra_args(path, gazelle_overrides),
            "patches": _get_patches(path, module_overrides),
            "patch_args": _get_patch_args(path, module_overrides),
        }

        archive_override = archive_overrides.get(path)
        if archive_override:
            go_repository_args.update({
                "urls": archive_override.urls,
                "strip_prefix": archive_override.strip_prefix,
                "sha256": archive_override.sha256,
                "patches": _get_patches(path, archive_overrides),
                "patch_args": _get_patch_args(path, archive_overrides),
            })
        else:
            go_repository_args.update({
                "sum": _get_sum_from_module(path, module, sums),
                "replace": getattr(module, "replace", None),
                "version": "v" + module.raw_version,
            })

        go_repository(**go_repository_args)

    # Create a synthetic WORKSPACE file that lists all Go repositories created
    # above and contains all the information required by Gazelle's -repo_config
    # to generate BUILD files for external Go modules. This skips the need to
    # run generate_repo_config. Only "importpath" and "build_naming_convention"
    # are relevant.
    _go_repository_config(
        name = "bazel_gazelle_go_repository_config",
        importpaths = {
            module.repo_name: path
            for path, module in module_resolutions.items()
        },
        module_names = {
            info.repo_name: info.module_name
            for path, info in bazel_deps.items()
        },
        build_naming_conventions = drop_nones({
            module.repo_name: get_directive_value(
                _get_directives(path, gazelle_overrides),
                "go_naming_convention",
            )
            for path, module in module_resolutions.items()
        }),
    )

    return _extension_metadata(
        module_ctx,
        root_module_direct_deps = root_module_direct_deps.keys(),
        # If a Go module appears as both a dev and a non-dev dependency, it has to be imported as a
        # non-dev dependency.
        root_module_direct_dev_deps = {
            repo_name: None
            for repo_name in root_module_direct_dev_deps.keys()
            if repo_name not in root_module_direct_deps
        }.keys(),
    )

def _get_sum_from_module(path, module, sums):
    entry = (path, module.raw_version)
    if hasattr(module, "replace"):
        entry = (module.replace, module.raw_version)

    if entry not in sums:
        # TODO: if no sum exist, this is probably because a go mod tidy was missed
        fail("No sum for {}@{} found".format(path, module.raw_version))

    return sums[entry]

def _safe_insert_sum(sums, entry, new_sum):
    if entry in sums and new_sum != sums[entry]:
        fail("Multiple mismatching sums for {}@{} found. {} vs {}".format(entry[0], entry[1], new_sum, sums[entry]))
    sums[entry] = new_sum

def _canonicalize_raw_version(raw_version):
    if raw_version.startswith("v"):
        return raw_version[1:]
    return raw_version

_config_tag = tag_class(
    attrs = {
        "check_direct_dependencies": attr.string(
            values = ["off", "warning", "error"],
        ),
    },
)

_from_file_tag = tag_class(
    attrs = {
        "go_mod": attr.label(mandatory = False),
        "go_work": attr.label(mandatory = False),
        "fail_on_version_conflict": attr.bool(default = True),
    },
)

_module_tag = tag_class(
    attrs = {
        "path": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "sum": attr.string(),
        "indirect": attr.bool(
            doc = """Whether this Go module is an indirect dependency.""",
            default = False,
        ),
        "build_naming_convention": attr.string(doc = """Removed, do not use""", default = ""),
        "build_file_proto_mode": attr.string(doc = """Removed, do not use""", default = ""),
        "parent_label": attr.label(
            doc = """The label of the go.mod or go.work file that this module was imported from.""",
            default = Label("//:MODULE.bazel"),
        ),
    },
)

_archive_override_tag = tag_class(
    attrs = {
        "path": attr.string(
            doc = """The Go module path for the repository to be overridden.

            This module path must be defined by other tags in this
            extension within this Bazel module.""",
            mandatory = True,
        ),
        "urls": attr.string_list(
            doc = """A list of HTTP(S) URLs where an archive containing the project can be
            downloaded. Bazel will attempt to download from the first URL; the others
            are mirrors.""",
        ),
        "strip_prefix": attr.string(
            doc = """If the repository is downloaded via HTTP (`urls` is set), this is a
            directory prefix to strip. See [`http_archive.strip_prefix`].""",
        ),
        "sha256": attr.string(
            doc = """If the repository is downloaded via HTTP (`urls` is set), this is the
            SHA-256 sum of the downloaded archive. When set, Bazel will verify the archive
            against this sum before extracting it.""",
        ),
        "patches": attr.label_list(
            doc = "A list of patches to apply to the repository *after* gazelle runs.",
        ),
        "patch_strip": attr.int(
            default = 0,
            doc = "The number of leading path segments to be stripped from the file name in the patches.",
        ),
    },
    doc = "Override the default source location on a given Go module in this extension.",
)

_gazelle_override_tag = tag_class(
    attrs = {
        "path": attr.string(
            doc = """The Go module path for the repository to be overridden.

            This module path must be defined by other tags in this
            extension within this Bazel module.""",
            mandatory = True,
        ),
        "build_file_generation": attr.string(
            default = "auto",
            doc = """One of `"auto"` (default), `"on"`, `"off"`.

            Whether Gazelle should generate build files for the Go module. In
            `"auto"` mode, Gazelle will run if there is no build file in the Go
            module's root directory.""",
            values = [
                "auto",
                "off",
                "on",
            ],
        ),
        "build_extra_args": attr.string_list(
            default = [],
            doc = """
            A list of additional command line arguments to pass to Gazelle when generating build files.
            """,
        ),
        "directives": attr.string_list(
            doc = """Gazelle configuration directives to use for this Go module's external repository.

            Each directive uses the same format as those that Gazelle
            accepts as comments in Bazel source files, with the
            directive name followed by optional arguments separated by
            whitespace.""",
        ),
    },
    doc = "Override Gazelle's behavior on a given Go module defined by other tags in this extension.",
)

_module_override_tag = tag_class(
    attrs = {
        "path": attr.string(
            doc = """The Go module path for the repository to be overridden.

            This module path must be defined by other tags in this
            extension within this Bazel module.""",
            mandatory = True,
        ),
        "patches": attr.label_list(
            doc = "A list of patches to apply to the repository *after* gazelle runs.",
        ),
        "patch_strip": attr.int(
            default = 0,
            doc = "The number of leading path segments to be stripped from the file name in the patches.",
        ),
    },
    doc = "Apply patches to a given Go module defined by other tags in this extension.",
)

go_deps = module_extension(
    _go_deps_impl,
    tag_classes = {
        "archive_override": _archive_override_tag,
        "config": _config_tag,
        "from_file": _from_file_tag,
        "gazelle_override": _gazelle_override_tag,
        "module": _module_tag,
        "module_override": _module_override_tag,
    },
)
