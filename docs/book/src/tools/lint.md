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
included, and 0 otherwise. `komp check` reports the same lints at the same
levels, without the tally.

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

style
  unused_import            warn                  an import whose module contributes no name this file writes
  wildcard_import          warn                  a `.*` import supplying few enough names to write out

perf
  implicit_copy            warn                  a value read through a borrow is copied to fill a by-value slot
  copy_after_move          warn                  an earlier move is copied instead, to keep the original readable
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

`[groups]` sets whole groups and `[lints]` single lints. Every group row
applies before every lint row, so a lint named on its own keeps its level
whatever its group is set to, wherever the two rows sit in the file.

In a workspace, a `lint.toml` beside the workspace's `kf.toml` applies to every
member, and a member's own `lint.toml` applies after it. A malformed line, a
section other than `[groups]` and `[lints]`, or a name that is no lint or group
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
