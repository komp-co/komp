# Lambdas

A lambda is an anonymous function written inline as an expression. The
compiler desugars it to a struct plus a trait implementation — no allocation,
no indirect call, no closure conversion at runtime.

## Syntax

```kflat
apply(|x: int32| x * 2, 4)
```

The parameter type is required, and there can be more than one:

```kflat
apply2(|a: int32, b: int32| a + b, 20, 22)
```

**The body is one expression, or a braced block.** A block's value is its last
statement when that statement is an expression:

```kflat
apply(|x: int32| {
    val doubled = x * 2
    doubled + 1
}, 3)
```

A block binds names of its own, and a local is never a capture — even when the
enclosing scope declares the same name, in which case the local shadows it. An
early `return` answers the lambda's value directly, and has to agree with the
type the trailing expression settles on.

A trailing `if` or `when` yields through its branches, as it does in a
[block used as a value](when.md#when-as-a-value): each path's last expression
is the lambda's value, and the paths must agree on a type.

```kflat
apply(|x: int32| {
    when x {
        0 => 0
        v if v < 0 => -1
        _ => 1
    }
}, 3)
```

A block that ends in something other than an expression makes the lambda void,
and so does a trailing `if` or `when` with a path that ends in a `void` call:
there the branches are statements, not values.

## What it desugars to

A lambda like `|x: int32| x * 2` becomes:

1. An anonymous struct holding the captures as fields.
2. An `impl` of the appropriate `Call` or `CallMut` trait on that struct, with
   the lambda body as the `call` method.

Because the compiler knows the concrete type of every lambda at the point it
is written, the call is monomorphized — no function pointer, no heap
allocation.

## Passing a lambda to a generic function

This is how lambdas are meant to be used, and the path that works today. A
lambda satisfies the `Call` trait matching its arity — `Call0` through
`Call3`, one per arity because there are no variadic generics:

```kflat
fun apply<F: Call1<int32>>(f: F, x: int32): int32 {
    return f(x)
}

fun main(): int32 {
    return apply(|x: int32| x * 3, 5)   // 15
}
```

The bound `F: Call1<int32>` constrains the *argument* type only. The result is
the trait's associated type, `F.Out`, which is why a predicate works through
the same bound:

```kflat
fun apply_out<F: Call1<int32>>(f: F, x: int32): F.Out {
    return f(x)
}

fun main(): int32 {
    println(apply_out(|x: int32| x > 2, 5))   // true
    return 0
}
```

`f(x)` on a local value is sugar for `f.call(x)`. The latter is the ordinary
trait method underneath; the shorter spelling works for any value whose type
provides a matching `call` method.

### Taking the argument by borrow

The bound's type argument may itself be a borrow, so a callable can read a
value it does not own:

```kflat
fun any_of<T, F: Call1<&T>>(xs: &List<T>, pred: F): bool {
    var i: uint64 = 0
    while i < xs.size() {
        if pred(xs.at(i)) { return true }
        i = i + 1
    }
    return false
}

fun main(): int32 {
    var xs = List.new<String>()
    xs.push(String.from("hello"))
    if any_of(&xs, |s| s.len() > 3) { return 0 }
    return 1
}
```

The lambda's parameter is inferred as `&String` here, and `xs` still owns every
element afterwards. This matters for an owning element type: a `Call1<T>` bound
takes its argument by value, so each element handed to it is a deep copy, while
`Call1<&T>` hands over a borrow and copies nothing.

`&T` and `&var T` are the same type argument as far as the bound is concerned —
both are one pointer, and they share a mangled name — so a type cannot provide
one `Call1` impl for each.

## Storing a lambda locally

A lambda can initialize a local directly. Its concrete synthesized type stays
local and can be called repeatedly:

```kflat
fun main(): int32 {
    val offset = 2
    val add = |x: int32| x + offset
    return add(40)   // 42
}
```

Stored lambdas own their captures by value. This lets a closure safely retain
a heap value until the closure itself is dropped:

```kflat
fun main(): int32 {
    val text = String.from("owned")
    val length = || text.len()
    if length() == 5 { return 0 }
    return 1
}
```

A stored lambda whose body mutates a capture implements `CallMut`, and its
binding must be a `var`:

```kflat
struct Counter { var value: int32 }

impl Counter {
    mutating fun bump(): int32 {
        self.value = self.value + 1
        return self.value
    }
}

fun main(): int32 {
    var counter = Counter { value: 0 }
    var next = || counter.bump()
    next()
    return next()   // 2
}
```

Stored closure values cannot yet be transferred: passing one to another call,
copying it to another binding, assigning it, returning it, boxing it, or
placing it in a struct is rejected. Borrow-typed, generic, and dynamic values
also cannot be captured by a stored lambda. Pass a lambda directly to a call
when it needs borrowed captures or generic dispatch.

## Captures

A read-only capture in a lambda passed directly to a call is a shared borrow.
Each captured variable becomes an `&T` field on the synthesized struct, and
the compiler dereferences that field inside the generated `call` method:

```kflat
fun apply<F: Call1<int32>>(f: F, x: int32): int32 {
    return f(x)
}

fun main(): int32 {
    val factor: int32 = 3
    return apply(|x: int32| x * factor, 5)   // 15
}
```

Calling a mutating method on a captured `var` makes it a mutable borrow. Such
a lambda implements `CallMut0` through `CallMut3`, so the receiving generic
must use the corresponding mutable bound:

```kflat
fun apply_mut<F: CallMut0>(f: F): void { f() }

fun main(): int32 {
    var text = String.from("a")
    apply_mut(|| text.append("b"))
    return 0
}
```

If the body consumes an owned value, the lambda captures that value by value
and also implements `CallMut`. This permits one-shot operations such as
returning a captured `String`:

```kflat
fun take_once<F: CallMut0>(f: F): String { return f() }

fun main(): int32 {
    val text = String.from("owned")
    val result = take_once(|| text)
    return 0
}
```

`Call` and `CallMut` are separate bounds. A lambda with a mutable or owned
capture does not satisfy `Call`.

Borrow-capturing lambdas must be passed directly to a call. A locally stored
lambda uses owned captures instead.

## Two limitations worth knowing

**A lambda cannot be returned or transferred after storage.** A lambda may
initialize one local and be called through that local, but its synthesized type
cannot cross another value boundary yet.

**A parameter needs its type where nothing expects one.** A bare `|x| x * 2` is
fine as an argument: its type comes from the `Call` bound on the parameter it is
passed to, so `apply(|x| x * 2, 3)` and `xs.map(|x| x * 2)` both read the
element type off the callee. A lambda bound to a `val` is passed to nothing, so
there is no bound to read and the annotation is required:

```console
$ komp check .
src/main.kf:3:13: error: lambda parameter `x` needs a type annotation (its type is read from the `Call` bound on the parameter the lambda is passed to, and this position declares none)
```

Where a bound does apply, a written annotation must agree with it. `any` on a
`List<int32>` hands each element over as an `int32`, so a parameter written
`&int32` is rejected at the parameter:

```kflat
import alloc.list.*

fun main(): int32 {
    var xs = List.new<int32>()
    xs.push(7)
    if xs.any(|n: &int32| *n == 7) { return 0 }
    return 1
}
```

```console
$ komp check .
src/main.kf:6:16: error: lambda parameter `n` is written `&int32`, but the `Call` bound it is passed to asks for `int32`
```

