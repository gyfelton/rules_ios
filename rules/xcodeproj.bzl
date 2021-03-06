load("@build_bazel_rules_apple//apple:providers.bzl", "AppleBundleInfo")
load("@bazel_skylib//lib:paths.bzl", "paths")

def _get_attr_values_for_name(deps, provider, field):
    return [
        getattr(dep[provider], field)
        for dep in deps
        if dep and provider in dep
    ]

_TargetInfo = provider()
_SrcsInfo = provider()

def _dir(o):
    return [
        x
        for x in dir(o)
        if x not in ("to_json", "to_proto")
    ]

def _xcodeproj_aspect_impl(target, ctx):
    providers = []

    deps = []
    deps += getattr(ctx.rule.attr, "deps", [])
    deps += getattr(ctx.rule.attr, "infoplists", [])
    deps.append(getattr(ctx.rule.attr, "entitlements", None))

    # TODO: handle apple_resource_bundle targets
    test_env_vars = {}
    test_commandline_args = {}
    if AppleBundleInfo in target:
        bundle_info = target[AppleBundleInfo]
        srcs = []
        bazel_name = target.label.name
        if ctx.rule.kind == "ios_unit_test":
            test_env_vars = getattr(ctx.rule.attr, "env", {})
            test_commandline_args = getattr(ctx.rule.attr, "args", {})

        info = struct(
            name = bundle_info.bundle_name,
            bundle_extension = bundle_info.bundle_extension,
            package = target.label.package,
            bazel_name = bazel_name,
            srcs = depset(srcs, transitive = _get_attr_values_for_name(deps, _SrcsInfo, "srcs")),
            build_files = depset([ctx.build_file_path], transitive = _get_attr_values_for_name(deps, _SrcsInfo, "build_files")),
            product_type = bundle_info.product_type[len("com.apple.product-type."):],
            test_env_vars = test_env_vars,
            test_commandline_args = test_commandline_args,
        )
        providers.append(
            _SrcsInfo(
                srcs = info.srcs,
                build_files = depset([ctx.build_file_path]),
                direct_srcs = srcs,
            ),
        )
        target_info = _TargetInfo(target = info, targets = depset([info], transitive = _get_attr_values_for_name(deps, _TargetInfo, "targets")))
        providers.append(target_info)
    elif ctx.rule.kind == "apple_framework_packaging":
        srcs = []
        info = struct(
            name = target.label.name,
            package = target.label.package,
            bazel_name = target.label.name,
            srcs = depset(srcs, transitive = _get_attr_values_for_name(deps, _SrcsInfo, "srcs")),
            build_files = depset([ctx.build_file_path], transitive = _get_attr_values_for_name(deps, _SrcsInfo, "build_files")),
            product_type = "framework",
            test_env_vars = test_env_vars,
            test_commandline_args = test_commandline_args,
        )
        target_info = _TargetInfo(target = info, targets = depset([info], transitive = _get_attr_values_for_name(deps, _TargetInfo, "targets")))
        providers.append(target_info)
    else:
        srcs = []
        for attr in _dir(ctx.rule.files):
            srcs += getattr(ctx.rule.files, attr, [])
        srcs = [f for f in srcs if not f.path.startswith("external/") and f.is_source]

        providers.append(
            _SrcsInfo(
                srcs = depset(srcs, transitive = _get_attr_values_for_name(deps, _SrcsInfo, "srcs")),
                build_files = depset([ctx.build_file_path], transitive = _get_attr_values_for_name(deps, _SrcsInfo, "build_files")),
                direct_srcs = srcs,
            ),
        )

        info = None
        actual = None
        if ctx.rule.kind in ("test_suite"):
            actual = getattr(ctx.rule.attr, "tests")[0]
        elif ctx.rule.kind in ("alias"):
            actual = getattr(ctx.rule.attr, "actual")

        if actual and _TargetInfo in actual:
            info = actual[_TargetInfo].target

        providers.append(
            _TargetInfo(target = info, targets = depset(transitive = _get_attr_values_for_name(deps, _TargetInfo, "targets"))),
        )

    return providers

_xcodeproj_aspect = aspect(
    implementation = _xcodeproj_aspect_impl,
    attr_aspects = ["deps", "actual", "tests", "infoplists", "entitlements", "resources", "test_host"],
)

def _xcodeproj_impl(ctx):
    xcodegen_jsonfile = ctx.actions.declare_file(
        "%s-xcodegen.json" % ctx.attr.name,
    )
    project_name = ctx.attr.project_name if ctx.attr.project_name else ctx.attr.name + ".xcodeproj"
    if "/" in project_name:
        fail("No / allowed in project_name")

    project = ctx.actions.declare_directory(project_name)
    nesting = ctx.label.package.count("/") + 1 if ctx.label.package else 0
    src_dot_dots = "/".join([".." for x in range(nesting + 3)])
    script_dot_dots = "/".join([".." for x in range(nesting)])

    proj_options = {
        "createIntermediateGroups": True,
        "defaultConfig": "Debug",
        "groupSortPosition": "none",
    }
    proj_settings = {
        "BAZEL_PATH": ctx.attr.bazel_path,
        "BAZEL_WORKSPACE_ROOT": "$SRCROOT/%s" % script_dot_dots,
        "BAZEL_STUBS_DIR": "$PROJECT_FILE_PATH/bazelstubs",
        "BAZEL_INSTALLER": "$BAZEL_STUBS_DIR/%s" % ctx.executable.installer.short_path,
        "CC": "$BAZEL_STUBS_DIR/clang-stub",
        "CXX": "$CC",
        "CLANG_ANALYZER_EXEC": "$CC",
        "CODE_SIGNING_ALLOWED": False,
        "DONT_RUN_SWIFT_STDLIB_TOOL": True,
        "LD": "$BAZEL_STUBS_DIR/ld-stub",
        "LIBTOOL": "/usr/bin/true",
        "SWIFT_EXEC": "$BAZEL_STUBS_DIR/swiftc-stub",
        "SWIFT_OBJC_INTERFACE_HEADER_NAME": "",
        "SWIFT_VERSION": 5,
    }

    targets = []
    if ctx.attr.include_transitive_targets:
        targets = depset(transitive = _get_attr_values_for_name(ctx.attr.deps, _TargetInfo, "targets")).to_list()
    else:
        targets = [t for t in _get_attr_values_for_name(ctx.attr.deps, _TargetInfo, "target") if t]

    xcodeproj_targets_by_name = {}
    xcodeproj_schemes_by_name = {}
    for target_info in targets:
        target_macho_type = "staticlib" if target_info.product_type == "framework" else "$(inherited)"
        xcodeproj_targets_by_name[target_info.name] = {
            "sources": [{
                "path": paths.join(src_dot_dots, s.short_path),
                "group": paths.dirname(s.short_path),
                "optional": True,
            } for s in target_info.srcs.to_list()],
            "type": target_info.product_type,
            "platform": "iOS",
            "settings": {
                "PRODUCT_NAME": target_info.name,
                "BAZEL_PACKAGE": target_info.package,
                "MACH_O_TYPE": target_macho_type,
            },
            "preBuildScripts": [{
                "name": "Build with bazel",
                "script": """
set -eux
cd $BAZEL_WORKSPACE_ROOT

$BAZEL_PATH build $BAZEL_PACKAGE:{bazel_name}
$BAZEL_INSTALLER
""".format(bazel_name = target_info.bazel_name),
            }],
        }
        if target_info.product_type == "framework":
            continue
        scheme_action_name = "test"
        if target_info.product_type == "application":
            scheme_action_name = "run"
        scheme_action_details = {"targets": [target_info.name]}

        test_env_vars = {}
        for k, v in getattr(target_info, "test_env_vars", {}).items():
            if ctx.attr.scheme_existing_envvar_overrides.get(k, None):
                test_env_vars[k] = ctx.attr.scheme_existing_envvar_overrides[k]
            else:
                test_env_vars[k] = v
        scheme_action_details["environmentVariables"] = test_env_vars

        test_commandline_args = getattr(target_info, "test_commandline_args", {})
        scheme_action_details["commandLineArguments"] = {}
        for arg in test_commandline_args:
            scheme_action_details["commandLineArguments"][arg] = True

        xcodeproj_schemes_by_name[target_info.name] = {
            "build": {
                "parallelizeBuild": False,
                "buildImplicitDependencies": False,
                "targets": {
                    target_info.name: [scheme_action_name],
                },
            },
            scheme_action_name: scheme_action_details,
        }

    xcodeproj_info = struct(
        name = paths.split_extension(project_name)[0],
        options = proj_options,
        settings = proj_settings,
        targets = xcodeproj_targets_by_name,
        schemes = xcodeproj_schemes_by_name,
    )

    ctx.actions.write(xcodegen_jsonfile, xcodeproj_info.to_json())

    ctx.actions.run(
        executable = ctx.executable._xcodegen,
        arguments = ["--quiet", "--no-env", "--spec", xcodegen_jsonfile.path, "--project", project.dirname],
        inputs = [xcodegen_jsonfile],
        outputs = [project],
    )
    install_script = ctx.actions.declare_file(
        "%s-install-xcodeproj.sh" % ctx.attr.name,
    )

    ctx.actions.expand_template(
        template = ctx.file._xcodeproj_installer_template,
        output = install_script,
        substitutions = {
            "$(project_short_path)": project.short_path,
            "$(project_full_path)": project.path,
            "$(installer_short_path)": ctx.executable.installer.short_path,
            "$(clang_stub_short_path)": ctx.executable.clang_stub.short_path,
            "$(clang_stub_ld_path)": ctx.executable.ld_stub.short_path,
            "$(clang_stub_swiftc_path)": ctx.executable.swiftc_stub.short_path,
        },
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = install_script,
            files = depset([xcodegen_jsonfile, project]),
            runfiles = ctx.runfiles(files = [xcodegen_jsonfile, project], transitive_files = depset(
                direct =
                    ctx.files.installer + ctx.files.clang_stub + ctx.files.ld_stub + ctx.files.swiftc_stub,
                transitive = [ctx.attr.installer[DefaultInfo].default_runfiles.files],
            )),
        ),
    ]

xcodeproj = rule(
    implementation = _xcodeproj_impl,
    attrs = {
        "deps": attr.label_list(mandatory = True, allow_empty = False, providers = [], aspects = [_xcodeproj_aspect]),
        "include_transitive_targets": attr.bool(default = False, mandatory = False),
        "project_name": attr.string(mandatory = False),
        "bazel_path": attr.string(mandatory = False, default = "bazel"),
        "scheme_existing_envvar_overrides": attr.string_dict(allow_empty = True, default = {}, mandatory = False),
        "_xcodeproj_installer_template": attr.label(executable = False, default = Label("//tools/xcodeproj-shims:xcodeproj-installer.sh"), allow_single_file = ["sh"]),
        "_xcodegen": attr.label(executable = True, default = Label("@com_github_yonaskolb_xcodegen//:xcodegen"), cfg = "host"),
        "clang_stub": attr.label(executable = True, default = Label("//tools/xcodeproj-shims:clang-stub"), cfg = "host"),
        "ld_stub": attr.label(executable = True, default = Label("//tools/xcodeproj-shims:ld-stub"), cfg = "host"),
        "swiftc_stub": attr.label(executable = True, default = Label("//tools/xcodeproj-shims:swiftc-stub"), cfg = "host"),
        "installer": attr.label(executable = True, default = Label("//tools/xcodeproj-shims:installer"), cfg = "host"),
    },
    executable = True,
)
