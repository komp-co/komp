# Trait objects

Every trait call in the [traits chapter](traits.md) is resolved at compile
time: the compiler knows the concrete receiver and emits a direct call. That
is what you want when the type is known. It is not what you want when the
caller should choose the implementation — a renderer that takes whatever the
caller has, a handler installed at startup, anything where one function serves
several unrelated types.

A trait object is a borrow that carries its implementation with it:

```kflat
trait Shape {
    fun area(): int32
}

struct Square { pub val side: int32 }
struct Rect { pub val w: int32  pub val h: int32 }

impl Shape for Square { fun area(): int32 { return self.side * self.side } }
impl Shape for Rect { fun area(): int32 { return self.w * self.h } }

fun total(a: &dyn Shape, b: &dyn Shape): int32 {
    return a.area() + b.area()
}

fun main(): int32 {
    val s = Square { side: 4 }
    val r = Rect { w: 5, h: 6 }
    return total(s, r)      // 16 + 30
}
```

`total` is compiled once. `a.area()` reads the function to call out of the
object at run time.

## The type is `&dyn Trait`

`dyn` names a trait object and must appear directly behind a borrow. There are
two forms:

| Type | Can call |
|---|---|
| `&dyn Trait` | the trait's non-`mutating` methods |
| `&var dyn Trait` | all of them, `mutating` included |

`&var dyn` writes through to the original value:

```kflat
trait Counter {
    mutating fun bump(): int32
}

struct Tally { pub var n: int32 }

impl Counter for Tally {
    mutating fun bump(): int32 {
        self.n = self.n + 1
        return self.n
    }
}

fun bump_twice(c: &var dyn Counter): int32 {
    c.bump()
    return c.bump()
}

fun main(): int32 {
    var t = Tally { n: 0 }
    val last = bump_twice(t)
    return last + t.n       // 2 + 2
}
```

Calling a `mutating` method through the shared form is an error, not a silent
copy:

```console
$ komp run .
src/main.kf:6:50: error: cannot call mutating method `bump` through shared trait object `&dyn Counter`
```

A bare `dyn Trait` is not a type you can write. It has no size — the whole
point is that the concrete value could be any of several — so it only exists
behind a borrow:

```console
$ komp run .
src/main.kf:2:20: error: `dyn Score` is unsized and must be used directly behind `&` or `&var`
```

## Making one

Anywhere a `&dyn Trait` is expected, pass the value. The conversion is
implicit, and writing the `&` yourself is equivalent:

```kflat
total(s, r)         // both fine
total(&s, &r)
```

"Anywhere a `&dyn Trait` is expected" means the annotated positions, not
inference: a `val` with the annotation, a parameter, a return type, both arms
of an `if`. A struct field is not among them — an object is a borrow, and a
borrow is not storable.

```kflat
fun pick(v: &Value): &dyn Score { return v }
fun read(v: &dyn Score): int32 { return v.score() }

fun main(): int32 {
    val left = Value { amount: 20 }
    val right = Value { amount: 22 }
    val local: &dyn Score = left
    val returned = pick(right)
    val chosen: &dyn Score = if true { local } else { returned }
    return read(chosen) + returned.score()
}
```

`Option<&dyn Trait>` works, and an absent object is `null` like any other
option:

```kflat
val absent: Option<&dyn Score> = null
val present: Option<&dyn Score> = value
val object = present ?: return 2
return object.score()
```

If the type does not implement the trait, the conversion is where you hear
about it:

```console
$ komp run .
src/main.kf:4:30: error: cannot convert `Value` to `&dyn Score`: no exact trait implementation exists
```

## Which traits can be objects

Not every trait can. A vtable is a fixed list of function pointers built once
per implementing type, so a trait qualifies only when each of its methods is
one entry in that list, callable knowing nothing about the receiver but its
address.

Four things disqualify a trait. Each is reported against the member
responsible, when the trait is used as `dyn`:

**An associated type.** The object type would have to name the choice, and the
whole point is that it is not known.

```console
src/main.kf:2:5: error: trait `Producer` cannot be used as dyn because it declares associated type `Item`
```

**A generic method.** One slot cannot stand for every instantiation.

```console
src/main.kf:1:16: error: trait method `map` cannot be used through dyn because it is generic
```

**A static method.** No receiver, so nothing to dispatch on.

```console
src/main.kf:1:17: error: static trait method `make` has no dynamic receiver
```

**`Self` anywhere but the receiver.** A method returning `Self` promises the
caller a type the object has deliberately forgotten.

```console
src/main.kf:1:19: error: trait method `duplicate` exposes `Self` outside its receiver
```

The check is on the whole trait, not on the method you happen to call. One
disqualifying method makes the trait unusable as an object, so it is worth
splitting a trait rather than accreting one.

What is allowed: trait type parameters, and default method bodies.

## Traits with type parameters

The type arguments are part of the object's identity. `&dyn Sink<int32>` and
`&dyn Sink<str>` are different types, and a type may implement both:

```kflat
trait Sink<T> {
    fun accept(value: T): int32
}

struct Receiver { pub val base: int32 }

impl Sink<int32> for Receiver {
    fun accept(value: int32): int32 { return self.base + value }
}

impl Sink<str> for Receiver {
    fun accept(value: str): int32 {
        if value.equals("ok") { return self.base + 2 }
        return 0
    }
}

fun take_number(r: &dyn Sink<int32>): int32 { return r.accept(20) }
fun take_text(r: &dyn Sink<str>): int32 { return r.accept("ok") }

fun main(): int32 {
    val r = Receiver { base: 10 }
    return take_number(r) + take_text(r)    // 30 + 12
}
```

The arguments must be complete — a partially applied trait is not an object
type:

```console
src/main.kf:2:21: error: trait `Sink` expects 1 type arguments, found 2
```

## What it costs

A `&dyn Trait` is two words: the address of the value and the address of a
vtable. Building one copies those two words. It does not allocate, clone,
retain, or release, and it does not take ownership — the value stays owned by
whoever owned it, exactly as with `&T`.

The vtable is one static constant per (type, trait) pair, emitted once. A call
through the object is an indirect call: a load and a jump, with no inlining
across it. Static dispatch stays the default for good reason; reach for `dyn`
when the indirection is what you actually want.

Because the object borrows, [the borrow rules](memory.md) apply. Storing one
in a struct and returning one out of a local are rejected; an object that
outlives its value any other way is not detected yet ([#36]).

## Limitations

**A collection of trait objects does not work yet.** `List.new<&dyn Shape>()`
is typed as the trait rather than as a list ([#73]):

```console
error: no method `push` on `Shape`
```

A `List<&Square>` of borrows of one concrete type does work. Holding a mixed
collection is the usual reason to want dynamic dispatch, so this is where the
gap bites hardest; and since a borrow cannot be stored in a struct, there is
no workaround yet beyond one list per concrete type, or passing the objects
one at a time.

**One trait per object.** There is no `&dyn Read + Write`, and no root
`Object` trait. If you need two traits' worth of behaviour, declare a trait
that requires both and implement it.

**Borrowed only.** There is no `Box<dyn Trait>`, so an object cannot outlive
the value it points at, and no downcasting back to the concrete type.

[#36]: https://github.com/komp-co/komp/issues/36
[#73]: https://github.com/komp-co/komp/issues/73
