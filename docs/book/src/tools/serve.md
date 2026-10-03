# The compiler as a service

`kflatc serve` keeps the compiler running and answers requests about a
project, so a tool does not start a process and re-read the disk for each
answer. It is how editor support and other tools reach the compiler. The
protocol on this page is the stable part: the compiler behind it changes
freely, and the requests and answers keep their shape.

## The conversation

The client starts `kflatc serve` and writes one JSON request per line to its
standard input. Every request gets exactly one JSON line on standard output,
in order. Nothing else is written there, and a blank line is passed over.

```console
$ kflatc serve
{"id":1,"method":"hello","params":{"protocol":1}}
{"id":1,"result":{"protocol":1,"compiler":"0.4.0"}}
{"id":2,"method":"check","params":{"target_dir":"/home/me/app/target/kflat","crate":{"name":"app","root":"/home/me/app","loads":["core","alloc"],"lints":[]}}}
{"id":2,"result":{"errors":1,"diagnostics":[{"schema_version":3,"severity":"error","code":null,"message":"init type doesn't match declared","byte_start":39,"byte_end":45,"file":"/home/me/app/src/main.kf","line":2,"column":20,"secondary":[],"fix":null}]}}
{"id":3,"method":"stage","params":{"path":"/home/me/app/src/main.kf","text":"fun main(): int32 {\n    val x: int32 = 4\n    return x\n}\n"}}
{"id":3,"result":null}
{"id":4,"method":"check","params":{"target_dir":"/home/me/app/target/kflat","crate":{"name":"app","root":"/home/me/app","loads":["core","alloc"],"lints":[]}}}
{"id":4,"result":{"errors":0,"diagnostics":[]}}
{"id":5,"method":"shutdown"}
{"id":5,"result":null}
```

A request is an object with a `method`, its `params` when it takes any, and an
`id`, an integer or a string, which the answer carries back unchanged. An
answer has either a `result` or an `error`:

```json
{"id":7,"error":{"code":"unknown_method","message":"no method named `compile`"}}
```

`code` is one of the names below, for a client to match on. `message` is for
people.

## Methods

| Method | Params | Result |
|---|---|---|
| `hello` | `protocol` | `protocol` and `compiler`, the kflatc version |
| `stage` | `path`, `text` | `null` |
| `unstage` | `path` | `null` |
| `check` | `target_dir`, `crate`, and `sources` when there are any | `errors`, a count, and `diagnostics`, an array |
| `symbols` | `path` | the file's declarations, nested |
| `folding` | `path` | the file's foldable ranges |
| `selection` | `path`, `offset` | the ranges around `offset`, innermost first |
| `hover` | `path`, `offset`, `crates` | what is at `offset`: its type, its declaration and that declaration's documentation |
| `signature` | `path`, `offset`, `crates` | the call around `offset`: its callee's parameters and which one `offset` is in |
| `references` | `path`, `offset`, `crates` | the declaration of what `offset` names, and every use of it |
| `completion` | `path`, `offset`, `crates` | what can be written at `offset` |
| `rename` | `path`, `offset`, `crates`, and `new_name` when there is one | every name to replace, or why the rename is refused |
| `inlays` | `path`, `crates` | the types of the file's bindings that name none |
| `tokens` | `path`, `crates` | every name in the file with what it is |
| `shutdown` | none | `null`, then the server exits 0 |

**`hello` comes first.** It names the protocol version the client speaks, and
anything else before it is refused as `not_ready`. A version this kflatc does
not speak is refused as `unsupported_protocol`, and the message says which it
does, so the client can tell its user which of the two to update.

**`stage` supplies a file's text** in place of what is on disk: an editor's
unsaved buffer. It stays staged, for every later request, until the same path
is staged again or `unstage`d. Staging empty text is an empty file, not an
absent one. The path is spelled as the checker spells it: the crate's `root`
followed by the file's path under it, such as `/home/me/app/src/main.kf`.

**`check` type-checks one crate** with its `_test.kf` files, as
`kflatc check` does, reading staged text where there is some. `crate` has the
shape of an entry in [`komp metadata`](cli.md#komp-metadata)'s `crates`
array, so a client passes one through unchanged: `name`, `root`, `loads` (the
interfaces to read, dependencies first), `lints` (`{"name", "level"}`
objects, or `name=level` strings) and `lint_options` (`{"name", "key",
"value"}` objects, the value a string or a number).
Other fields are passed over. `target_dir` is `komp metadata`'s, where the
dependencies' interfaces are. They must already be there; `komp check` puts
them there.

`sources`, when given, lists crates whose interface is written from source
before the check, staged text included, dependencies first: `{"name", "root",
"loads"}` objects, as `komp metadata` lists workspace members. The checked
crate, and each source after the one written, reads those interfaces instead
of the target directory's, so an edit to a library that is not saved yet
reaches the crate using it. A source that does not compile keeps the
interface in the target directory. Nothing is written to the target
directory. A kflatc older than this field passes over it and checks against
the target directory, so a client can always send it. Each diagnostic is the object `komp check
--format=json` prints, described under
[Structured fixes](cli.md#structured-fixes). A lint row that names no lint,
or an option no lint has, is
reported as an error diagnostic, as `kf.toml` reports it.

**`symbols`, `folding` and `selection` only parse** the file, from its staged
text or from disk, so they answer on a file that does not type-check, and
cost milliseconds.

**The rest type the crates around the file.** `crates` lists them as
`{"name", "root"}` objects, dependencies first and the file's own crate
last: a crate's `loads` from `komp metadata`, then the crate itself. They
are typed from source, staged text included, once; every later typed request
naming the same crates reuses that until a `stage` or `unstage` changes a
buffer, so moving around a file that is not being edited costs no more
checking. A file the last crate does not compile is refused as
`not_in_crate`. `rename` without a `new_name` asks only whether the name at
`offset` can be renamed, as an editor does before asking for the new name.

**The server stops** after answering `shutdown`, or when its standard input
ends. Either way it exits 0.

## Answers

Offsets are byte offsets into the file, zero-based and end-exclusive, the
convention diagnostics use, in the params and in every answer. They are not
lines and columns because only the client knows the position encoding its
own client negotiated. Each answer carries a `schema_version` of its own and
the `file` and `offset` it was asked about. The examples below show only the
`result`, for a crate at `/w`.

**`symbols`** is the declaration tree, which an outline, a breadcrumb bar and
"go to symbol in file" all read:

```json
{"schema_version":1,"file":"/w/src/point.kf","symbols":[{"name":"Point","kind":"struct","detail":"","byte_start":0,"byte_end":33,"children":[{"name":"x","kind":"field","detail":"int32","byte_start":23,"byte_end":24,"children":[]}]}]}
```

Kinds are KFlat's words, not any protocol's numbers: `function`, `method`,
`struct`, `enum`, `variant`, `field`, `trait`, `impl`, `extern`, `type`. A
declaration that failed to parse is left out: it names nothing to navigate
to.

**`folding`** is the regions an editor offers to collapse: the import block
at the top of the file, then every declaration and every method.

```json
{"schema_version":1,"file":"/w/src/point.kf","ranges":[{"byte_start":0,"byte_end":33,"kind":"region"}]}
```

**`selection`** is what expand-selection grows through: the spans covering
`offset`, innermost first, ending at the whole declaration.

```json
{"schema_version":1,"file":"/w/src/main.kf","offset":91,"ranges":[{"byte_start":91,"byte_end":92},{"byte_start":91,"byte_end":96},{"byte_start":43,"byte_end":98}]}
```

There is no step for the enclosing statement, because a statement's span is
its leading keyword rather than its extent; the chain goes from the outermost
expression straight to the declaration.

**`hover`** is the innermost expression covering `offset` (hovering `a` in
`f(a + 1)` answers about `a`, not the call), its type as its author would
write it (`List<int32>`, not the name it links under), and, when it names a
declaration, that declaration's signature and documentation:

```json
{"schema_version":2,"file":"/w/src/main.kf","offset":195,"type":"int32","signature":null,"documentation":null,"byte_start":195,"byte_end":200}
```

`type` is null when `offset` covers no expression: whitespace, a keyword, a
comment, a parameter's name. That is not an error; most of a file is not an
expression. The name a `val` or `var` binds answers with the type of what
initializes it. A field after a `.` answers with its declaration as the
signature (`val x: int32`) and the documentation above it.

**`inlays`** is the types nobody wrote down: one hint per `val` or `var` with
no annotation, at the byte where its name ends.

```json
{"schema_version":1,"file":"/w/src/main.kf","inlays":[{"byte_offset":133,"label":": int32"},{"byte_offset":159,"label":": List<int32>"}]}
```

**`signature`** is the callee of the innermost call around `offset`, its
parameters, and which one `offset` is in:

```json
{"schema_version":1,"file":"/w/src/main.kf","offset":143,"label":"add(a: int32, b: int32): int32","parameters":[{"label":"a: int32"},{"label":"b: int32"}],"active_parameter":1}
```

`label` is null when `offset` is not inside a call, or inside one whose
callee the crates do not declare. The active parameter counts the commas
directly inside the call, so it keeps working while the argument being typed
does not parse yet.

**`references`** is where the name at `offset` was declared, and every use
of it. Each span carries its own file, since a use can be anywhere in the
crate.

```json
{"schema_version":1,"file":"/w/src/lib.kf","offset":90,"declaration":{"file":"/w/src/lib.kf","byte_start":4,"byte_end":10},"references":[{"file":"/w/src/lib.kf","byte_start":90,"byte_end":96},{"file":"/w/src/other.kf","byte_start":36,"byte_end":42}]}
```

Every span is a name: the declaration is `helper`, not the `fun` before it,
and a use is the callee, not the whole call. `offset` may be on the
declaration or on any use; both answer the same. The declaration is not
repeated among the uses. Only top-level declarations answer: a parameter or
a local resolves through the typechecker's own scope, which the resolver
does not build, so one answers with a null `declaration` and no uses rather
than a guess from spelling.

**`tokens`** is every name in the file with what it is, sorted by position,
which is what semantic highlighting paints:

```json
{"schema_version":1,"file":"/w/src/lib.kf","tokens":[{"byte_start":41,"byte_end":42,"type":"variable"},{"byte_start":84,"byte_end":93,"type":"function"}]}
```

Types are `variable`, `function`, `method`, `field` and `type`.

**`completion`** after a `.` is the fields and instance methods of the
receiver's type:

```json
{"schema_version":2,"file":"/w/src/lib.kf","offset":398,"prefix":"","receiver_type":"Point","items":[{"label":"x","kind":"field","detail":"int32"},{"label":"sum","kind":"method","detail":"sum(): int32"}]}
```

Where the receiver ends is found in the text, not the tree: the cursor sits
after a `.` and perhaps a partly typed name, neither of which parses yet. So
the compiler scans back over the name, expects a `.`, and types what comes
before it. `prefix` is the partial name; the client filters on it. A
`static fun` is left out, since it takes no receiver, and a generic's
members are shown as declared (`push(item: T)`, not `push(item: int32)`).
Extensions come after the type's own members, and only those a call on the
receiver would pick: one whose bound the type does not meet is left out, and
a type's own method hides an extension of the same name. Hover on a method
call picks the same way.

Anywhere else, the items are the names in scope at `offset`, and
`receiver_type` is null:

```json
{"schema_version":2,"file":"/w/src/lib.kf","offset":271,"receiver_type":null,"prefix":"","items":[{"label":"seed","kind":"parameter","detail":"int32"},{"label":"total","kind":"local","detail":"int32"},{"label":"Point","kind":"struct","detail":""},{"label":"println","kind":"function","detail":"(v: T): void"}]}
```

The keywords come first, then the locals live at that point and the
enclosing function's parameters and `self`, then the declarations the file
can name, gated by the same import rules the checker uses. A local declared below the cursor, or inside a block the cursor is not
in, is not offered. `@test` functions are left out: nothing calls them by
name. Kinds are `keyword`, `local`, `parameter`, `function`, `struct`,
`enum` and `trait` in scope, and `field` or `method` after a `.`.

When the receiver has no type the checker could name, `receiver_type` is
null and there are no items: a list built from spelling would be worse than
none.

**`rename`** is every span to replace, the declaration's own name included,
or the reason the rename is refused:

```json
{"schema_version":1,"file":"/w/src/lib.kf","offset":8,"new_name":"scaled","ok":true,"error":null,"range":{"file":"/w/src/lib.kf","byte_start":8,"byte_end":14},"edits":[{"file":"/w/src/lib.kf","byte_start":8,"byte_end":14},{"file":"/w/src/lib.kf","byte_start":133,"byte_end":139},{"file":"/w/src/other.kf","byte_start":40,"byte_end":46}]}
```

A rename that changes which declaration a name refers to still compiles and
no longer means what it did, so `ok` is false, with the reason in `error` and
no `edits`, when:

| | |
|---|---|
| the new name is not one | it must lex as a single identifier |
| the new name is taken | another top-level declaration in the crate has it |
| the new name is the old one | that is not a rename |
| `offset` is not on a name | a keyword or whitespace names no declaration |
| the declaration is not the crate's | it is in a dependency; rename it there |

Without a `new_name`, every check that needs none runs, and `range` is the
name under the cursor. Collisions are checked crate-wide rather than at each
use: the resolver stamps only top-level declarations, so a local shadowing
the new name somewhere would go unseen, which is why rename declines on
locals entirely.

## Errors

| `code` | Means |
|---|---|
| `parse_error` | The line is not a JSON object with a `method`; its `id` is `null` |
| `not_ready` | A request came before `hello` |
| `unsupported_protocol` | `hello` named a version this kflatc does not speak |
| `unknown_method` | No method has that name |
| `invalid_params` | A required field is missing or has the wrong type |
| `not_in_crate` | A typed request's file is not one the last of its `crates` compiles |
| `no_such_file` | A file named in the params is neither staged nor on disk |
| `check_failed` | The crate could not be checked at all, such as a dependency's interface missing from `target_dir` |

A `check` that finds errors in the code is not an error answer: it is a
`result` whose `errors` is not 0.

## Versions

The protocol is version 1. Adding a method, a param or a field to a result
keeps the version, so a client passes over what it does not know. Removing or
changing one raises the version. komp's own checks run a scripted session
through `kflatc serve` and compare the shape of every answer, so a compiler
change that would break a client fails there first.

## Finding the compiler

`komp metadata` names the `kflatc` it builds with, beside the crates and the
`target_dir`. A client that asks it talks to the same compiler that builds the
user's code.
