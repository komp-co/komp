# Editor support

The editor tooling lives in two repositories beside the compiler.
[kf-lsp](https://github.com/komp-co/kf-lsp) holds `kflat_lsp`, the language
server, written in KFlat. [kf-extensions](https://github.com/komp-co/kf-extensions)
holds the VS Code extension and the TextMate grammar.

## The language server

`kflat_lsp` speaks the Language Server Protocol over standard input and
output, so any editor with an LSP client can use it. It never parses KFlat
itself: it keeps one [`kflatc serve`](serve.md) running and passes it the
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
| Go to definition, find references | where a top-level name is declared, and every use of it |
| Rename | a declaration and every use of it, or the reason it would change what the code means |
| Semantic highlighting | a name coloured by what it is |

The outline, folds and selection come from a parse, so they answer while the
file is half-written. The rest come from the file's crate typed once and
reused until the next edit, so moving around a file costs no more checking.
Go-to-definition, references and rename reach top-level declarations only: a
parameter or a local answers with nothing, since the resolver stamps only
top-level names.

It is built with a komp from this tree, checked out beside kf-lsp; kf-lsp's
README has the steps. It asks `komp` on `PATH` about the project, or the one
`KOMP_BIN` names. In Neovim, start it from an autocmd:

```lua
vim.filetype.add({ extension = { kf = "kflat" } })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "kflat",
  callback = function(args)
    vim.lsp.start({
      name = "kflat-lsp",
      cmd = { vim.fn.expand("~/path/to/kf-lsp/target/kflat/kflat_lsp") },
      root_dir = vim.fs.root(args.buf, "kf.toml"),
      cmd_env = { KOMP_BIN = vim.fn.expand("~/path/to/komp/.build/komp") },
    })
  end,
})
```

It negotiates `positionEncoding: utf-8` when the client offers it, and counts
UTF-16 code units otherwise.

## VS Code

`vscode/` in kf-extensions is the extension: the grammar, diagnostics from
`komp check`, and quick fixes. Its other features ran `komp query`, which
komp no longer has; they come back when the extension is rebuilt on the
language server.

## Where the highlighting comes from

The grammar is generated, not written. `scripts/generate-grammar.js` reads the
keyword spellings out of `kw_str`, the operator spellings out of `op_str`, and
the builtin type names out of `is_runtime_type_name` — the same tables the
compiler lexes and diagnoses with — and emits
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
