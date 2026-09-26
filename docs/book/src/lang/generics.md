# Generics

Generic functions, structs, enums, and impl blocks let you write code that
works over any type satisfying a set of bounds. Each concrete instantiation is
monomorphized: the compiler emits one copy per set of type arguments, so there
is no runtime type erasure or indirection.

## Generic functions

```kflat
fun identity<T>(x: T): T {
    return x
}
```

Type parameters go between `<...>` after the function name. They are written
at the call site only when they cannot be inferred:

```kflat
val a = identity(42)           // T = int32, inferred
val b = identity<String>(42)   // wrong: int32 literal can't become String
```

## Generic structs and enums

```kflat
struct Pair<A, B> {
    var first: A
    var second: B
}
```

Write the type arguments **on the literal**, not only on the binding:

```kflat
val p = Pair<int32, bool> { first: 1, second: true }
```

`val p: Pair<int32, bool> = Pair { ... }` — arguments on the annotation, bare
name on the literal — is rejected: the literal is checked against the
template, so a field reads as `A` rather than `int32` ([#3]). Until that is
fixed, put the arguments on the literal every time.

Enum variants work the same way:

```kflat
enum Maybe<T> {
    Just(T)
    Nothing
}
```

## Generic impl blocks

An `impl` block names the type parameters in the same position the type
declares them. They are then available in every method in the block:

```kflat
struct Cell<T> {
    var v: T
}

impl Cell<T: Copy> {
    fun get(): T {
        return self.v
    }
}
```

`get` hands out a copy of `v`, so the block says `T` can be copied: the bound
is what lets it compile, and what stops a `Cell<String>` from using it. See
[In generic code](memory.md#in-generic-code).

(`Box` is reserved for the builtin owning heap pointer, so a type of your own
cannot use that name.)

`self` is implicit, as in any impl block — it is never written as a
parameter.

A method that returns its own type with the parameters *transposed*
(`Pair<A, B>` returning a `Pair<B, A>`) is wrongly rejected: the literal's
fields are checked against the unswapped parameters ([#2]). Keep the parameter
order stable.

## Bounds

A bound restricts a type parameter to types that implement a given trait:

```kflat
fun min<T: Compare>(a: T, b: T): T {
    if a < b { return a }
    return b
}
```

`T: Compare` means the compiler knows that `T` has a `compare` method and
therefore the `<` and `>` operators work. Without the bound, the function
body cannot call any method on `T` except those implied by the bound.

Bounds can appear on an `impl` block too, restricting which types the methods
apply to. The impl declares its parameters in a list after `impl`, bounds
included, and the target then uses them:

```kflat
trait Show { fun show(): int32 }

struct Pair<A, B> {
    pub val a: A
    pub val b: B
}

impl<A: Show, B> Show for Pair<A, B> {
    fun show(): int32 { return self.a.show() + 1 }
}
```

Every parameter the target uses must be declared in the list, and every
declared one used. The older spelling puts the bound in the target's own list,
`impl Show for Pair<A: Show, B>`, and means the same; a parameter may be
bounded in one of the two places, not both.

A bound on the impl block is what a lazy iterator adapter needs, since the
source iterator and the callable are the *struct's* parameters rather than any
one method's.

A bound on a trait impl's parameter is a condition on the impl. core writes
`impl Clone for Option<T: Clone>`, so `Option<X>` is `Clone` only when `X` is,
and a bound asking for `Clone` checks the argument too:

```kflat
struct Unique { pub var n: int32 }

fun dup<T: Clone>(v: &T): T { return v.clone() }

fun main(): int32 {
    val o: Option<Unique> = Unique { n: 1 }
    val p = dup<Option<Unique>>(&o)
    return 0
}
```

```console
$ komp check .
src/main.kf:7:13: error: type `Option<Unique>` does not implement trait `Clone` (required by bound `T: Clone` on `dup`)
```

`.equals()` under a `T: Equal` bound works whether `T` is a primitive or a
struct, as does `==` on the same bound. Primitives satisfy `Equal`, `Compare`
and `Display` intrinsically, with no `impl` to find.

## Monomorphization

KFlat does not erase type parameters at runtime. When the compiler sees
`identity(42)`, it produces a function named `identity__int32` (or similar)
that takes an `int32` and returns an `int32`. A call to `identity<String>`
produces a separate function. There is one copy of the code per concrete
type-argument tuple.

This has two effects:

1. **No runtime cost**: a generic call is as cheap as a non-generic one. No
   boxing, no indirect dispatch, no dynamic check.

2. **Code size grows**: N distinct instantiations produce N copies of the
   function body. This is the same trade-off C++ templates make.

## When type arguments are inferred

Three sources are consulted, all flowing forwards:

- **The argument types.** `identity(42)` gives `T = int32`.
- **The impl a bound names.** A parameter that appears only inside another
  parameter's bound is read off that parameter's impl, once the arguments have
  fixed it.
- **The expected type at the binding or the return slot.** A function that
  returns `Option.Some(x)` where `Option<int32>` is expected instantiates
  `T = int32` with nothing written.

`T` below takes no value, but `C` does, and `List<int32>` implements
`Iterable<int32>`, so `T = int32`:

```kflat
import alloc.list.*

fun count_all<C: Iterable<T>, T>(c: &C): int32 {
    var n = 0
    while _x in c { n = n + 1 }
    return n
}

fun main(): int32 {
    var xs = List.new<int32>()
    xs.push(4)
    return count_all(&xs)    // 1
}
```

```kflat
val opt: Option<bool> = Option.Some(true)   // T = bool, from the annotation
val none: Option<int32> = Option.None       // no payload — the annotation carries it
```

`Option.None<int32>` is not the way to write a typed `None`; annotate the
binding instead.

A static call with no value argument has nothing of its own to go on, so the
slot is what types it. All four of these work:

```kflat
val a: List<int32> = List.new()                    // an annotation
fun empty(): List<int32> { return List.new() }     // a return type
count(List.new())                                  // a parameter
fun empty_of<T>(): List<T> { return List.new() }   // a generic function's own
```

Without an annotation, the binding's **first use** decides instead: a method
call whose arguments fix every type argument, or a slot of known type. A
`null` bound the same way is typed by the first optional slot it reaches:

```kflat
var xs = List.new()
xs.push(1)                   // a List<int32> from here on

var ages = HashMap.new()
ages.insert(String.from("ada"), 36)   // both type arguments at once

var filled = List.new()
fill(&var filled)            // fill(xs: &var List<int32>)

val none = null
takes(none)                  // takes(p: int32?)
```

Only the first use counts. A use that says nothing, such as `xs.size()`
before any `push`, leaves the call open, and an open call is reported,
naming both repairs:

```console
$ komp check .
./src/main.kf:4:14: error: cannot tell what `List.new()` is over — write the type argument (`List.new<...>()`), or annotate the binding
    var xs = List.new()
             ^~~~~~~~~~
check: found errors
```

Once the first use has decided, later ones are checked against it:
`xs.push(true)` after `xs.push(1)` is an error.

[#2]: https://github.com/komp-co/komp/issues/2
[#3]: https://github.com/komp-co/komp/issues/3
