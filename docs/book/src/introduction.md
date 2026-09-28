<img src="https://raw.githubusercontent.com/komp-co/kf-extensions/main/brand/kiwi.svg" width="96" alt="The KFlat paper kiwi">

# Introduction

KFlat is a systems programming language that compiles to C. It is
self-hosted: the compiler, komp, is itself written in KFlat. Apart from a
small C shim for bootstrap and platform calls, the language needs no
runtime.

## The thesis

KFlat is built on one claim: a systems language can have modern syntax, a
flexible type system, and deterministic performance — without hiding
costs. Nothing the compiler adds is invisible. Generics are monomorphized
to ordinary functions at compile time. Dispatch is always static — no
vtables, no indirection unless you write one. There is no garbage
collector, no mandatory runtime, and no boxed representation implied by
the type alone. If your program allocates, it is because you asked for it.

The language family KFlat belongs to is small: Rust without lifetimes, C
with traits, Zig with a richer type system. It is a research language and
an opinionated one. It does not try to be a better Rust and it does not
try to be comfortable enough for Python programmers. It is for people who
want to know what their program does and who are willing to be told.

## What KFlat is not

KFlat is not a memory-safe language in the Rust sense. It has a move
checker and second-class borrows, but borrows are not lifetime-checked.
Use-after-free through a borrow pointer will compile and will crash (or
worse) at runtime. The model is being tightened — see
[Memory](lang/memory.md) for what is checked today and what is not.

KFlat is not a scripting language. The compiler does not have a REPL, an
interactive mode, or hot-reload. Programs are compiled to C, which is then
compiled by a C toolchain. The compilation model is batch: a single
program, one binary at the end.

KFlat is not JavaScript. It does not have exceptions, promises, or an
event loop. Error handling is explicit — through `Result<T, E>` and
`Option<T>` — and there is no implicit null.

## Maturity

KFlat is self-hosting and the compiler is in active use — it compiles
itself daily. The language has working generics, traits, enums with
payloads, pattern matching, iterators, and a growing standard library.

What is missing is larger than what is present. Several features documented
in this book work only under constraints or not at all. Each chapter
states those constraints where they apply. A consolidated list is in
[Limitations and known gaps](limitations.md). If you hit something that is
not documented there, file an issue.
