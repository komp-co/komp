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
| `check` | `target_dir`, `crate` | `errors`, a count, and `diagnostics`, an array |
| `symbols` | `path` | the file's declarations, nested |
| `folding` | `path` | the file's foldable ranges |
| `selection` | `path`, `offset` | the ranges around `offset`, innermost first |
| `hover` | `path`, `offset`, `crates` | what is at `offset`: its type, its declaration and that declaration's documentation |
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
interfaces to read, dependencies first) and `lints` (`name=level` rows).
Other fields are passed over. `target_dir` is `komp metadata`'s, where the
dependencies' interfaces are. They must already be there; `komp check` puts
them there. Each diagnostic is the object `komp check
--diagnostic-format=json` prints, described under
[Structured fixes](cli.md#structured-fixes). A lint row that names no lint is
reported as an error diagnostic, as `kf.toml` reports it.

**`symbols`, `folding` and `selection` only parse** the file, from its staged
text or from disk, so they answer on a file that does not type-check, and
cost milliseconds. Each result is the object
[`komp query`](cli.md#komp-query) prints for the same question, byte offsets
included; `offset` is a byte offset too.

**`hover` types the crates around the file.** `crates` lists them as
`{"name", "root"}` objects, dependencies first and the file's own crate
last: a crate's `loads` from `komp metadata`, then the crate itself. They
are typed from source, staged text included, once; every later typed request
naming the same crates reuses that until a `stage` or `unstage` changes a
buffer, so hovering around a file that is not being edited costs no more
checking. The result is the object `komp query hover` prints. A file the
last crate does not compile is refused as `not_in_crate`.

**The server stops** after answering `shutdown`, or when its standard input
ends. Either way it exits 0.

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
