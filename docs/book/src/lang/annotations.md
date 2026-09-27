# Annotations

Annotations start with `@` and apply to the declaration that follows. KFlat
accepts `@test`, `@test_disabled`, `@allow(...)`, `@derive(...)`,
`@no_mangle`, `@lang(...)` and `@prelude`. Any other annotation is an error.

A declaration may carry several, one per line.

## @test

`@test` marks a function for `komp test`:

```kflat
@test
fun addition_works(): void {
    assert_eq(1 + 1, 2, "one plus one")
}
```

It may only annotate a function. See [Writing tests](../tools/testing.md) for
running and filtering tests.

`@test_disabled` also annotates a function, but leaves it out of `komp test`.
It is used by the compiler's test suite for disabled integration tests.

## @derive

`@derive(...)` synthesizes implementations for the listed traits:

```kflat
@derive(Default, Equal)
struct Counter { pub var value: int32 }
```

It may annotate a struct or an enum, though not every trait reaches both:

| Trait | Struct | Enum | Generated behavior |
| --- | --- | --- | --- |
| `Default` | yes | — | Builds a value with each field's default value. |
| `Equal` | yes | yes | Compares every field, or matching enum payloads, with `==`. |
| `Hash` | yes | — | Combines every field's hash. |
| `Clone` | yes | yes | States that copying the value is allowed. |
| `Copy` | yes | yes | States that the value may be copied bitwise; also derives `Clone`. |

Every field used by a derived `Equal` implementation must itself implement
`Equal`.

`Clone` is the odd one: it generates no copying code, because there is none to
generate. The compiler already knows how to deep-copy any type — it synthesizes
that alongside the drop glue. What `@derive(Clone)` adds is the *permission*:
the type now satisfies a `T: Clone` bound, and `.clone()` on it is something
you asked for rather than something that happened to work.

`Copy` is checked where it is derived: every field must itself be `Copy`, and
the type must not implement `Drop`. See [Copy](memory.md#copy).

## @allow

`@allow(...)` silences the named lints for diagnostics inside the declaration
it annotates:

```kflat
@allow(unused_import, dead_code)
fun scratch(): void { }
```

The names are the ones a diagnostic reports as its `code`. `lint.toml` sets
the same levels for a whole crate, and `-A`/`-W`/`-D` set them for one build;
the innermost setting wins, so an `@allow` beats both. See
[Linting](../tools/lint.md).

`implicit_copy` and `copy_after_move` — the copies the compiler inserts for you
— are the two worth knowing about, because they are the ones you may
deliberately accept. See [Memory](memory.md).

## @no_mangle

`@no_mangle` keeps a struct's or enum's C name exactly as written, without the
crate prefix komp normally adds, so hand-written C can name it:

```kflat
@no_mangle
pub struct Pair {
    pub var left: int32
    pub var right: int32
}
```

The C type is `Pair`, and its methods are `Pair_<method>`. It may only annotate
a struct or an enum, and two `@no_mangle` types with the same name anywhere in
the program are an error, since their C names would collide.

## @lang

`@lang("key")` is how the standard library tells the compiler which of its
types the language itself builds on. alloc's `String` carries
`@lang("string")`, which makes it the type a string literal becomes, the type
`${...}` renders into, and the type a `str` converts up into.

The compiler knows the keys, not the type names. `string` is the only key so
far.

Only `core`, `alloc` and `std` may use it, only on a struct or an enum, and
each key may be declared once in a program. Your own crates cannot use it:

```console
$ komp check .
./src/main.kf:2:8: error: `@lang(...)` is reserved for the standard library (core, alloc and std)
    struct Text {
           ^~~~
check: found errors
```

## @prelude

`@prelude` marks a function as part of the prelude — the names a program may
use without writing an import. `println`, `assert_eq`, `min`, `range` and the
common `str`/`String` methods are all `@prelude` in the standard library.

Resolution asks the mark, never the crate name: the caller's own crate
answers first, then its imports, then any `@prelude` function. A name the
caller's own crate defines still shadows a prelude name, and a prelude name
still shadows nothing an import names.

Only `core`, `alloc` and `std` may use it, and only on a function. Every
*other* `pub` function in the standard library is no longer ambient — it is
reachable only by importing its module. The prelude is deliberately small;
helpers like `str.last_index_of` or `str.replace` are not in it.
