# Limitations and known gaps

What you cannot do in KFlat, compiled from what the other chapters could not
demonstrate. Each entry names the tracking issue.

Most of these share a shape worth internalising: **`komp check` passing does
not mean the program builds.** Several gaps below are caught by the C compiler
or the linker, naming a mangled symbol you never wrote. When that happens,
look here before assuming your code is wrong.

If you hit something not recorded here, search the issue tracker, then file it
with a reduced program and the exact output.

## Borrows are not fully lifetime-checked

A borrow (`&T`, `&var T`) is a second-class pointer into memory owned by
another value. Two of the three ways to outlive the owner are now closed:

- **Storing one** is rejected — a borrow in a struct field or an enum payload,
  with `str` counting as a borrow.
- **Returning one out of a local** is rejected. `return &x` for a local `x`,
  or `return owned.as_str()` for a `String` the function built, no longer
  compiles.

- **Changing the origin** while a borrow of it is live is rejected: mutating
  it or reassigning it between the borrow's binding and its last use.
- **Moving the origin** while a borrow of it is live is rejected: passing it
  to a parameter that takes it by value. Lending it with `&` is unaffected.

Containers are still accepted — `List<&T>` and `Option<&T>` compile, and
whether an element outlives its origin is not tracked. Dropping an origin
early is not rejected either.

The rule until then: do not keep a borrow past the point where the owner is
alive. The borrow checker that closes the rest is [#36].

## No overload resolution

Two definitions in one scope may not share a name, whether they differ by
parameter type or by arity:

```kflat
fun twice(x: int64): int64   { return x * 2 }
fun twice(x: float64): float64 { return x * 2.0 }
```

`komp check` reports it, naming the second definition:

```console
$ komp check .
src/main.kf:2:5: error: `twice` is already defined in this module
```

Give the two functions different names, or make one generic over a bound — `core.math`'s
`abs` covers every numeric width that way.

The same name on *different* types is fine, and so are several same-named
methods on one type when they come from different traits (`From<int32>` and
`From<str>` both give you `from`).

## Lambdas

- **A stored lambda cannot be transferred or returned.** A lambda may directly
  initialize one local and be called there. Passing that local onward, copying
  or assigning it, boxing it, placing it in a struct, or returning it is not
  implemented yet. Stored lambdas also reject borrow-typed, generic, and
  dynamic captures.
- **A parameter needs its type where nothing expects one.** As an argument,
  `|x| x * 2` reads its parameter type from the `Call` bound on the parameter it
  is passed to. Bound to a `val` it is passed to nothing, so the annotation is
  required:

```console
$ komp check .
src/main.kf:3:13: error: lambda parameter `x` needs a type annotation (its type is read from the `Call` bound on the parameter the lambda is passed to, and this position declares none)
```


## Generics

- A generic struct literal typed only by its binding
  (`val c: Cell<int32> = Cell { v: 5 }`) is rejected, because the literal is
  checked against the template ([#3]). Put the arguments on the literal.
- A method returning its own type with the parameters transposed is wrongly
  rejected ([#2]).

## Extension functions

- An [extension on a trait](lang/extension-receivers.md) iterates `self` by
  value: `while x in &self` is an error, since no trait declares the borrowing
  iterator it needs.
- An impl cannot name one instance of a generic type, even one the crate
  declares: `impl Wrap<Point> { ... }` is an error. Write an extension,
  `fun Wrap<Point>.name()`, instead ([#41]).
- There is no module-qualified call such as `geometry.manhattan(&p)` ([#47]);
  two imported extensions that tie are separated by importing only one.
- `Self` cannot be written in an extension to name the receiver's type
  ([#53]). Write the receiver as a parameter, `fun <C: Trait> C.name()`, and
  name `C`.

## std is thin, and not implicit

`core` and `alloc` are injected automatically; `std` must be declared in
`[dependencies]`. What it does not have: directory walking, networking,
threads ([#58]). It does have standard input and error, and `std.time`: a
clock, a sleep, and a monotonic `Instant`. The process's arguments are in core
(`arg_count()`, `arg_at(i)`).

## Trait objects are borrowed, and cannot be collected

[`&dyn Trait`](lang/trait-objects.md) exists and dispatches dynamically, but
this first slice stops short in three places:

- **A collection of them does not work.** `List.new<&dyn Shape>()` is typed
  as the trait rather than as a list ([#73]). A `List<&Square>` of one
  concrete type works; a mixed collection is the usual reason to want dynamic
  dispatch, so this is the gap that matters.
  Holding one in a struct of your own is rejected outright — a borrow is not
  storable, and `&dyn Trait` is a borrow like any other. So is holding a
  `List<&dyn Shape>` there, since the rule reads through the container.
- **Borrowed only.** No `Box<dyn Trait>`, so an object cannot outlive what it
  points at, and no downcasting back to the concrete type.
- **One trait per object.** No `&dyn Read + Write` and no root `Object` trait.

Object safety is enforced: a trait with an associated type, a generic method,
a static method, or `Self` outside the receiver is rejected where it is used
as `dyn`, naming the member responsible.

## Supertraits

A trait can require another (`trait Ranked: Named`). The requirement is
enforced where the trait is implemented, type arguments included, and a bound
on the requiring trait reads through it — the required trait's methods, its
associated types, and the operators it provides. One thing is missing:

**A trait with requirements cannot be a trait object** ([#20]):

```console
error: trait `Ranked` cannot be used as dyn because it requires `Named` —
supertrait vtables are not implemented yet
```

Static bounds on the same trait are unaffected — only `&dyn Ranked` is refused.

Redeclaring an inherited associated type is rejected, but two *requirements*
declaring the same one is not: `trait Both: Left + Right` where `Left` and
`Right` each declare `type Out` compiles, and `T.Out` on a `T: Both` then
reaches two declarations ([#21]).

## Tooling

The [VS Code extension](https://github.com/komp-co/kf-extensions) and the
[language server](https://github.com/komp-co/kf-lsp) are subprocess bridges:
each answers by running the compiler per save or per request, so answers cost
a process launch and a re-check. A KFlat-native server that links the compiler
in-process is [kf-lsp#1](https://github.com/komp-co/kf-lsp/issues/1). There is
no formatter ([#15]).

A package's feature flags are not read ([#79]).

## Where the compiler itself stands

The compiler self-hosts and the fixpoint holds: komp compiles its own source
to C that is byte-identical to the C it was built from. CI runs `komp test`
over each of the compiler's crates with the freshly built binary, so komp does
test itself.

Separate compilation through `.kfi` interfaces is the default build path and
is still being hardened — the crate-qualification issues above are all
symptoms of it. Unity builds take a different path through the driver and do
not agree with it in every case.

[#2]: https://github.com/komp-co/komp/issues/2
[#3]: https://github.com/komp-co/komp/issues/3
[#15]: https://github.com/komp-co/komp/issues/15
[#20]: https://github.com/komp-co/komp/issues/20
[#21]: https://github.com/komp-co/komp/issues/21
[#36]: https://github.com/komp-co/komp/issues/36
[#41]: https://github.com/komp-co/komp/issues/41
[#47]: https://github.com/komp-co/komp/issues/47
[#53]: https://github.com/komp-co/komp/issues/53
[#58]: https://github.com/komp-co/komp/issues/58
[#73]: https://github.com/komp-co/komp/issues/73
[#79]: https://github.com/komp-co/komp/issues/79
