load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//internal/bzlmod:go_deps.bzl", "fail_on_version_conflict")

def _go_sum_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, _EXPECTED_GO_SUM_PARSE_RESULT, parse_go_sum(_GO_SUM_CONTENT))
    return unittest.end(env)

go_sum_test = unittest.make(_go_sum_test_impl)
