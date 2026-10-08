# Editor support

The editor tooling lives in two repositories beside the compiler.
[kf-lsp](https://github.com/komp-co/kf-lsp) holds the language server, written
in KFlat and published to the package index as `komp_lsp`. [kf-extensions](https://github.com/komp-co/kf-extensions)
holds the VS Code extension and the TextMate grammar.

## The language server

The server speaks the Language Server Protocol over standard input and
output, so any editor with an LSP client can use it. It never parses KFlat
itself: it keeps one [`kflatc serve`](https://github.com/komp-co/kf-lang/blob/main/docs/book/src/tools/serve.md) running and passes it the
editor's unsaved text, so every answer is about the buffer on screen, not
the file as last saved. `komp metadata` tells it where that kflatc is and how
the workspace is laid out.

| | |
|---|---|
| Diagnostics | the crate of the edited file, checked once typing pauses for 300 ms |
| Quick fixes | the repair a diagnostic carries, offered on its line |
| Outline | breadcrumbs, the outline view and "go to symbol in file" |
| Folding | the import block and every declaration |
| Expand selection | the chain of spans around the cursor |
| Hover | the type of the expression under the pointer, and the signature and documentation of what it names |
| Inlay hints | the type of every `val` or `var` written without one |
| Signature help | the callee's parameters while typing a call |
| Completion | the members of a receiver after `.`, and the names in scope elsewhere |
| Go to definition, find references | where a name is declared, and every use of it: functions, types, methods, fields, parameters, locals and annotations |
| Go to implementation | the impls of a trait or a type, a type's extensions, and each impl's version of a trait method |
| Rename | a declaration and every use of it, or the reason it would change what the code means |
| Semantic highlighting | a name coloured by what it is |

The outline, folds and selection come from a parse, so they answer while the
file is half-written. The rest come from the file's crate typed once and
reused until the next edit, so moving around a file costs no more checking.

Install it once, and every editor starts it the same way:

```sh
komp tool install komp_lsp
```

An editor runs `komp lsp` in the project's directory. komp runs the
version the project's [`[tools]`](../start/projects.md#pinning-tools) table
pins, else the installed one, and replaces itself with it, so stopping the
server leaves nothing behind. komp hands the server its own path as
`KOMP_BIN`, and the server asks that komp about the project. In Neovim, start
it from an autocmd:

```lua
vim.filetype.add({ extension = { kf = "kflat" } })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "kflat",
  callback = function(args)
    local root = vim.fs.root(args.buf, "kf.toml")
    vim.lsp.start({ name = "komp-lsp", cmd = { "komp", "lsp" }, cmd_cwd = root, root_dir = root })
  end,
})
```

It negotiates `positionEncoding: utf-8` when the client offers it, and counts
UTF-16 code units otherwise.

## VS Code

`vscode/` in kf-extensions is the extension: the grammar, file icons for
`.kf` files, tests and komp's manifests, and everything in the table above,
from the language server. It starts `komp lsp` once per project, the
outermost directory above a file holding a `kf.toml`, so a workspace's member
crates share one server. It runs the Run and Test lenses' commands as tasks.
When the server does not start, it offers to run `komp tool install
komp_lsp`. `kflat.kompPath` names a komp that is not on `PATH`.

## Where the highlighting comes from

The grammar is generated, not written. `scripts/generate-grammar.js` reads the
keyword spellings out of `kw_str`, the operator spellings out of `op_str`, and
the builtin type names out of `is_runtime_type_name` and the library types
marked `@lang` — the same tables the compiler lexes and diagnoses with — and
emits
`syntaxes/kflat.tmLanguage.json`. Regenerate it after changing any of them.
The generator reads a komp checkout beside kf-extensions, or the one
`KOMP_REPO` names:

```sh
cd vscode
node scripts/generate-grammar.js            # rewrite the grammar
node scripts/generate-grammar.js --check    # fail if it is out of date
```

Adding a keyword or an operator to the compiler makes the generator fail
until the new spelling is given a scope, rather than leaving it silently
uncolored.

A regex grammar cannot know what a name means, only what it looks like, so
its colouring is lexical: every `UpperCamelCase` word reads as a type, and a
variable is not distinguished from a function. The language server's
semantic tokens answer that properly — the grammar paints instantly and
offline, and the semantic tokens correct it once the crate has been checked.

The grammar paints every literal form the lexer reads. It marked four of
them as errors for as long as the lexer rejected them; the lexer grew all
four, and a rule that outlives its limitation paints correct source red —
so those rules are gone, and the grammar's test suite pins the scopes they
have now.
