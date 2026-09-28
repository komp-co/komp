# Linting

`komp lint` checks a project and reports its lints: the warnings the compiler
gives about code that compiles but probably should not stay as it is. After
the diagnostics it tallies what it found, lint by lint.

```console
$ komp lint shapes
/home/me/shapes/src/main.kf:2:1: warning: unused import `alloc.list.List`: nothing in this file names anything it declares
    import alloc.list.List
    ^~~~~~~~~~~~~~~~~~~~~~
/home/me/shapes/src/main.kf:1:1: warning: wildcard import `core.args.*` supplies one name; name it
    import core.args.*
    ^~~~~~~~~~~~~~~~~~
lint: 0 errors, 2 warnings
  unused_import    1
  wildcard_import  1
```

It exits 1 when anything was reported as an error, a lint set to `deny`
included, and 0 otherwise. `komp check` and the editor report the same lints
at the same levels, without the tally. `komp build` reports only the lints
the compiler meets while compiling, such as `implicit_copy`: the ones that
read the source as written run when it is checked. The lints that need to
know a value's type, such as `unused_result`, run only once the crate has
type-checked without an error.

## Levels and groups

Every lint has a level:

| Level | Effect |
|---|---|
| `allow` | Not reported |
| `warn` | Reported as a warning |
| `deny` | Reported as an error, which fails the command |

and belongs to one group, which says what kind of problem it finds:

| Group | Finds |
|---|---|
| `correctness` | Code that is wrong |
| `suspicious` | Code that is probably wrong |
| `style` | Code that could be written more plainly |
| `complexity` | Code that does something simple in a roundabout way |
| `perf` | Code that does work it need not |
| `pedantic` | Nitpicks; most are allowed unless asked for |
| `restriction` | Rules a project may choose to hold itself to; allowed unless asked for |

A group's name sets every lint in it, wherever a lint's name is accepted, and
`all` names every lint. `komp lint --list` prints each lint with its group,
its level here, its default when that differs, and what it reports:

```console
$ komp lint --list
correctness
  unauthorized_copy        deny                  a copy is inserted into a type that does not implement `Clone`

suspicious
  deref_through_temporary  warn                  `*` through a `Box` owned by a call's result, freed at the end of the statement
  empty_if                 warn                  an `if` whose branches are both empty
  self_assignment          warn                  a variable assigned to itself
  unused_variable          warn                  a local that is bound and never read
  unreachable_code         warn                  a statement after a `return`, `break` or `continue` in the same block
  self_comparison          warn                  a variable compared with itself
  double_negation          warn                  `!` applied to a `!`, as in `!(!x)`
  unused_result            warn                  a `Result` an expression statement drops, error and all
  float_equality           warn                  `==` or `!=` between floats other than zero, outside tests

style
  unused_import            warn                  an import whose module contributes no name this file writes
  wildcard_import          warn                  a `.*` import supplying few enough names to write out
  needless_var             warn                  a `var` that is read and never changed
  len_zero                 allow                 a length compared with zero, which `is_empty()` says
  needless_bool            warn                  branches that give `true` and `false`, which the condition already is
  manual_index_loop        allow                 a `while` loop that counts by hand what `while i in 0..n` counts
  bool_comparison          warn                  a comparison with `true` or `false`
  collapsible_if           allow                 an `if` whose only statement is another `if`
  non_snake_case_function  warn                  a function not named in lower_snake_case
  non_snake_case_variable  warn                  a local or parameter not named in lower_snake_case
  non_camel_case_type      warn                  a struct, enum or trait not named in UpperCamelCase
  non_camel_case_variant   warn                  an enum variant not named in UpperCamelCase

complexity
  redundant_cast           warn                  a cast to the type the value already has
  too_many_parameters      warn                  a function taking more parameters than `max`, `self` aside
      max = 7                                  the most parameters a function may take
  identity_op              warn                  an operation that leaves its value as it is, as `x + 0` or `x * 1`
  too_many_fields          allow                 a struct holding more fields than `max`
      max = 12                                 the most fields a struct may hold
  long_function            allow                 a function spanning more lines than `max_lines`
      max_lines = 100                          the most lines a function may span
  deep_nesting             allow                 blocks nested deeper than `max_depth` inside one function
      max_depth = 5                            the most blocks that may enclose a statement

perf
  implicit_copy            warn                  a value read through a borrow is copied to fill a by-value slot
  copy_after_move          warn                  an earlier move is copied instead, to keep the original readable
  clone_on_copy            warn                  `.clone()` on a value whose type derives `Copy`, which copies anyway

pedantic
  redundant_else           allow                 an `else` after a branch that ends in `return`, `break` or `continue`
  missing_docs             allow                 a public declaration with no `///` comment
  unused_parameter         allow                 a parameter the function never reads
  unused_option            allow                 an `Option` an expression statement drops

restriction
  long_line                allow                 a line wider than `max_columns` characters
      max_columns = 120                        the most characters a line may hold
  long_file                allow                 a file longer than `max_lines` lines
      max_lines = 400                          the most lines a file may hold
  magic_number             allow                 a number past `max_plain` written where it is used; tests, constants, ranges and indexes aside
      max_plain = 2                            the largest number that may be written without a name
  shadowed_variable        allow                 a local bound again under a name the function already binds
  todo_comment             allow                 a `TODO` or `FIXME` comment, which is work an issue should hold
```

## lint.toml

A project sets its levels in `lint.toml`, beside `kf.toml`:

```toml
# Hold the style lints as errors, but let wildcard imports through.
[groups]
style = "deny"

[lints]
wildcard_import = "warn"
```

`[groups]` sets whole groups and `[lints]` single lints. A lint that takes
options, as `--list` shows under it, is set with a table instead, giving its
level, its options, or both:

```toml
[groups]
complexity = "warn"

[lints]
too_many_parameters = { max = 2 }
long_line = { level = "deny", max_columns = 100 }
```

With that lint.toml, over this `src/main.kf`:

```kflat
fun main(): int32 {
    return add_all(1, 2, 3)
}

fun add_all(a: int32, b: int32, c: int32): int32 {
    return a + b + c
}
```

```console
$ komp lint shapes
/home/me/shapes/src/main.kf:5:5: warning: `add_all` takes 3 parameters; the most is 2
    fun add_all(a: int32, b: int32, c: int32): int32 {
        ^~~~~~~
lint: 0 errors, 1 warning
  too_many_parameters  1
```

An option's value is a whole number; `--list` shows the value in force and,
when lint.toml changed it, the default.

Every group row applies before every lint row, so a lint named on its own keeps its level
whatever its group is set to, wherever the two rows sit in the file.

In a workspace, a `lint.toml` beside the workspace's `kf.toml` applies to every
member, and a member's own `lint.toml` applies after it. A malformed line, a
section other than `[groups]` and `[lints]`, a name that is no lint or group,
or an option the lint does not take
is an error that names the file, and fails the command.

## Where a level comes from

Later settings win:

1. the lint's default, which `komp lint --list` shows
2. `lint.toml`: the workspace's, then the crate's own
3. the `[lint]` table in `kf.toml`, which sets single lints as `[lints]` does
4. `-A`, `-W` and `-D` on the command line, by lint or group name, in order
5. [`@allow(...)`](../lang/annotations.md#allow) on the declaration a
   diagnostic is in

`--deny-warnings` then turns every warning left into an error.

```console
$ komp lint -A all shapes
lint: no problems
```

## Options

| Flag | Effect |
|---|---|
| `--list` | Print every lint, its group and its level; check nothing |
| `--fix` | Apply the repairs the diagnostics suggest, as [`komp fix`](cli.md#structured-fixes) does |
| `--diagnostic-format=json` | One JSON object per diagnostic, and no tally |
| `-A`, `-W`, `-D <lint or group>` | Allow, warn or deny, for this run |
| `--deny-warnings` | Report every warning as an error |
| `-p <crate>`, `--workspace` | Lint a workspace member, or every one |
