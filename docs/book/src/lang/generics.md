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

A literal reads its type arguments off its fields, as a call reads them off
its arguments, through `&T`, `Ptr<T>` and nested instances as well as a bare
`T`:

```kflat
val p = Pair { first: 1, second: true }               // Pair<int32, bool>
val q = Pair<int64, bool> { first: 1, second: true }  // written out
```

A parameter no field mentions cannot be read off anything, so it has to be
written:

```text
error: cannot infer `T` for `Tagged` from its fields: write the type arguments, as `Tagged<...> { ... }`
```

The binding's annotation is not consulted: `val p: Pair<int64, bool> = Pair {
first: 1, second: true }` reads `first` as `int32` and is rejected ([#3]).
Write the arguments on the literal when the fields alone would pick a
different type.

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
declared one used, by the target or by the trait's arguments. A parameter only
the trait's arguments name is taken from each call: `N` below is the length of
whatever array is passed, and each length gets its own `from`.

```kflat
struct Total {
    val sum: int64
}

impl<N: uint64> From<int64[N]> for Total {
    static fun from(items: int64[N]): Total {
        var sum: int64 = 0
        while x in items { sum = sum + x }
        return Total { sum: sum }
    }
}

fun main(): int32 {
    val two: int64[2] = [1, 2]
    val three: int64[3] = [3, 4, 5]
    return (Total.from(two).sum + Total.from(three).sum) as int32   // 3 + 12
}
```

Such an impl has no `&dyn` form: there is one per length, and none until a
call names it.

```console
$ komp check .
src/main.kf:7:9: error: `B` is declared in `impl<...>` but neither the target nor the trait's arguments use it
    impl<A, B> Show for Pair<A> {
            ^
```

The older spelling puts the bound in the target's own list,
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
src/main.kf:7:13: error: type `Unique?` does not implement trait `Clone` (required by bound `T: Clone` on `dup`)
```

`.equals()` under a `T: Equal` bound works whether `T` is a primitive or a
struct, as does `==` on the same bound. Primitives satisfy `Equal`, `Compare`
and `Display` intrinsically, with no `impl` to find.

## Value parameters

A parameter can stand for a value instead of a type. Its bound tells the two
apart: a bound naming a trait makes a type parameter, and a bound naming a
type makes a value parameter of that type.

```kflat
struct Residue<M: uint64> {
    val value: uint64
}

fun wrap<M: uint64>(v: uint64): Residue<M> {
    return Residue<M> { value: v % M }
}

fun main(): int32 {
    val x: Residue<7> = wrap<7>(12)
    return x.value as int32    // 5
}
```

Inside the body, `M` is a constant of its type. The argument is an integer
literal, negative ones included (`Residue<-3>`, given a signed type). A value
parameter's type is a primitive integer, or another parameter of the same
declaration bounded by core's `Integer`:

```kflat
struct Residue<I: Integer, M: I> {
    val value: I
}

fun wrap<I: Integer, M: I>(v: I): Residue<I, M> {
    return Residue<I, M> { value: v % M }
}

fun modulus_of<I: Integer, M: I>(r: &Residue<I, M>): I { return M }

fun main(): int32 {
    val x: Residue<int32, 9> = wrap(16)
    return x.value + modulus_of(&x)    // 7 + 9
}
```

Value arguments are inferred like type arguments: `wrap(16)` takes `I` and
`M` from the declared type of `x`, and `modulus_of(&x)` reads them off its
argument. Each set of arguments is its own instance, so `Residue<int32, 9>`,
`Residue<int32, 7>` and `Residue<int64, 9>` are three different types.

An argument is checked against its parameter like a literal against a slot:

```kflat
struct Tiny<N: uint8> {
    val x: int32
}

fun main(): int32 {
    val t = Tiny<300> { x: 1 }
    return 0
}
```

```console
$ komp check .
src/main.kf:6:18: error: `300` does not fit in `uint8`, the type of `N` on `Tiny`
```

A type where a value belongs, or a value where a type belongs, is an error
too. There is no arithmetic in a type: `Residue<M + 1>` cannot be
written.

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

A static call's arguments bind the type's parameters the way a generic
function's do, so `Pair.of(4, true)` needs nothing written:

```kflat
struct Pair<A, B> {
    val first: A
    val second: B
}

impl<A, B> Pair<A, B> {
    static fun of(first: A, second: B): Pair<A, B> {
        return Pair<A, B> { first: first, second: second }
    }
}

fun main(): int32 {
    val p = Pair.of(4, true)          // a Pair<int32, bool>
    return if p.second { p.first } else { 0 }
}
```

The arguments decide: `Pair.of(4, true)` is a `Pair<int32, bool>` even where a
`Pair<int64, bool>` is expected, so write `4 as int64` there. Every parameter
must be bound by some argument; when one is not, as `B` in a
`static fun of(first: A): Half<A, B>`, write them all:
`Half.of<int32, bool>(4)`.

A static call with no value argument has nothing of its own to go on, so the
slot is what types it. All four of these work:

```kflat
val a: List<int32> = List.new()                    // an annotation
fun empty(): List<int32> { return List.new() }     // a return type
count(List.new())                                  // a parameter
fun empty_of<T>(): List<T> { return List.new() }   // a generic function's own
```

Without an annotation, the binding's **uses** decide instead: the first
method call whose arguments fix every type argument, or slot of known type. A
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

A use that says nothing, such as `xs.size()` before any `push`, leaves the
call open for a later use. One that no use ever completes is reported,
naming both repairs:

```console
$ komp check .
./src/main.kf:4:14: error: cannot tell what `List.new()` is over — write the type argument (`List.new<...>()`), or annotate the binding
    var xs = List.new()
             ^~~~~~~~~~
check: found errors
```

Once a use has decided, every other is checked against it:
`xs.push(true)` after `xs.push(1)` is an error.

[#2]: https://github.com/komp-co/komp/issues/2
[#3]: https://github.com/komp-co/komp/issues/3
