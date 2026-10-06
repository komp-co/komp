# Writing tests

Tests in KFlat are `@test`-annotated functions that live alongside the source
they test. They share the crate's scope — they can call non-`pub` functions
and access private types.

## Anatomy of a test

A test function lives in a file named `<module>_test.kf` next to
`<module>.kf`. For example, tests for `src/math.kf` go in `src/math_test.kf`:

```kflat
// src/math_test.kf
import testing.test

@test
fun test_add(): void {
    val result = add(2, 3)
    assert_eq(result, 5, "2 + 3 should be 5")
}
```

The function is annotated with `@test`, returns `void`, and takes no
arguments. `@test(name = "...")` shows a name of your choosing in the report,
`@test(panics = FaultKind.UnwrapNone)` passes only when the test panics with
that kind, and `@disabled("reason")` beside `@test` keeps a test checked but
out of the run (see [`@test`](https://github.com/komp-co/kf-lang/blob/main/docs/book/src/lang/annotations.md#test)). `@test` and
`@disabled` are imported from `testing` like any other name, and the crate
names `testing` in its [`[dev-dependencies]`](../start/projects.md#dev-dependencies). The test file and the source file share the same scope — `add` is
callable without any import, because the test file sits in the same
directory, and so the same module, as the source.

## Assertions

`core.assert` provides three functions:

| Function | Behaviour |
|---|---|
| `assert(condition: bool, label: str)` | Panics if the condition is false |
| `assert_eq<T: Equal>(a: T, b: T, label: str)` | Panics if `a == b` is false |
| `fail(label: str)` | Panics unconditionally |

`assert_eq` needs `T: Equal` and nothing else — it compares with `==`, so it
works for primitives and for any type with an `Equal` impl. Only the label is
printed; the two values are not, so write a label that identifies the case:

```kflat
assert_eq(result, 42, "should be the answer")
```

A failed assertion **panics**, which ends that test function — anything after
it in the same test does not run. The runner catches this per test and
continues with the next one.

## Running tests

```console
$ komp test .
running 3 tests
test test_add_is_five ...
ok
test test_add_is_wrong ...
2 + 3 should be 99
panic[assertion_failed]: assertion failed
FAILED
test test_runs_after_failure ...
ok

test result: FAILED. 2 passed, 1 failed
```

komp builds a test binary whose `main` hands every `@test` function of the
crate, and every `@disabled` one, to `testing`'s
[`run_tests`](https://github.com/komp-co/kf-lang/blob/main/docs/book/src/libs/testing.md#running-tests), and runs it. A disabled test is
reported as `ignored`, with its reason, and counted in the result line.
The exit code is 0 when every test passed and 1 otherwise — it is not a
failure count.

Each test runs in a process of its own, so a failed assertion ends that test
and not the run. Two run at a time by default; `KOMP_TEST_JOBS=<n>` sets how
many. Each test's output is held until its turn and printed in order, so the
report reads the same whatever finishes first. With `KOMP_TEST_JOBS=1` a
test's output streams as it runs.

A test program runs with `KFLATC` naming the compiler komp runs, and `KOMP`
the komp running the tests, so a test that builds a project of its own drives
the same tools.

## One assertion per test

The convention is one assertion per test function. This makes the failure
output unambiguous — the test name tells you exactly what broke. Split
unrelated assertions into separate named tests:

```kflat
@test
fun test_add_is_commutative(): void {
    assert_eq(add(2, 3), add(3, 2), "add is commutative")
}

@test
fun test_add_zero_is_identity(): void {
    assert_eq(add(7, 0), 7, "adding zero changes nothing")
}
```

`assert_eq` is the only equality assert. The per-type helpers it replaced —
`assert_eq_bool`, `assert_eq_str`, `assert_eq_u64` and friends — no longer
exist.

## Directive fixtures

End-to-end behaviour tests live under `tests/cases/` as standalone `.kf`
files with `//!` directives:

```kflat
//! run: exit 0
//! deps: core, alloc
```

| Directive | Meaning |
|---|---|
| `//! run: exit N` | Build and run; assert exit code N |
| `//! build: fail` | The build must fail |
| `//! deps: a, b` | Add `libs/<a>` and `libs/<b>` as dependencies |
| `//! broken: WHY` | Known-broken — report but do not fail the suite |

These are run by CI and are the ground truth for what the language does.
Add one when you fix a bug or land a feature.
