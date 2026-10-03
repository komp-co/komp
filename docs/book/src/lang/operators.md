# Operators

Operators in KFlat do two things: they evaluate to a value, and they
dispatch through a trait method. Every operator maps to a trait, so any type
that implements the trait gets the operator for free.

## Arithmetic

| Operator | Trait | Method |
|---|---|---|
| `+` | `Add` | `add(other: T): T` |
| `-` | `Sub` | `sub(other: T): T` |
| `*` | `Mul` | `mul(other: T): T` |
| `/` | `Div` | `div(other: T): T` |
| `%` | `Mod` | `mod(other: T): T` |

For the built-in integer and float types the traits are already implemented
and no import is required:

```kflat
val a = 10
val b = 3
println(a + b)    // 13
println(a - b)    // 7
println(a * b)    // 30
println(a / b)    // 3
println(a % b)    // 1
```

For a user-defined type, implement the trait — no import: a trait resolves
by name.

```kflat
pub struct Vec2 {
    var x: int32
    var y: int32
}

impl Add for Vec2 {
    fun add(o: &Vec2): Vec2 { return Vec2 { x: self.x + o.x, y: self.y + o.y } }
}

fun main(): int32 {
    val a = Vec2 { x: 10, y: 20 }
    val b = Vec2 { x: 3, y: 4 }
    val c = a + b    // dispatches to Vec2.add — no magic
    return c.x
}
```

## Comparison

| Operator | Trait | Method |
|---|---|---|
| `==` | `Equal` | `equals(other: T): bool` |
| `!=` | `Equal` | derived from `!equals` |
| `<`, `>`, `<=`, `>=` | `Compare` | `compare(other: T): int32` |

`Compare.compare` returns a negative value when `self < other`, zero when
equal, positive when `self > other`. The relational operators call it once and
check the sign:

```kflat
if p < q { ... }
// desugars to: p.compare(q) < 0
```

Import `core.equal.*` and `core.compare.*` to use these on your own types.

## Operands are read through a borrow

An operand of type `&T` is the `T` it points at, the same way a field access or
a method call reaches through a borrow. Write the operator directly:

```kflat
fun is_seven(n: &int32): bool { return n == 7 }
fun total(a: &int32, b: &int32): int32 { return a + b }
```

Both operands are read this way, so two borrows compare the values they point
at rather than their addresses — `a == b` is true for two variables that hold
the same value. An explicit `*n` means exactly the same thing and is still
accepted.

The pointee's type is what has to answer the operator, so comparing two `&P`
needs `impl Equal for P` just as comparing two `P` does.

`str` is not a borrow in this sense: it is its own type, and `==` on it is a
content comparison as always.

## Logical

`&&`, `||`, and `!` work on `bool`s only:

```kflat
val ready = true
val done = false
if ready && !done { ... }
if ready || done { ... }
```

Both `&&` and `||` short-circuit: the right-hand side is not evaluated if the
left-hand side determines the result.

## Bitwise

| Operator | Trait | Method |
|---|---|---|
| `&` | `And` | `and(other: T): T` |
| `\|` | `Or` | `or(other: T): T` |
| `^` | `Xor` | `xor(other: T): T` |
| `>>` | `Shr` | `shr(other: T): T` |
| `<<` | `Shl` | `shl(other: T): T` |

These are available for integer types and through the respective traits for
user types.

## Type cast: as

`expr as Type` is an explicit cast. It is checked by the compiler — you cannot
cast between arbitrary types, only between numeric widths:

```kflat
val narrow: int8 = 5
val wide = narrow as int32    // ok: widening
val back = wide as int8       // ok: narrowing
```

Inside `unsafe`, `as` also takes an address as a raw pointer. A prefix `&`,
`&var` or `*` binds tighter than `as`, so `&var x as Ptr<int32>` is the
address of `x`:

```kflat
fun main(): int32 {
    var x: int32 = 30
    val p = unsafe { &var x as Ptr<int32> }
    unsafe { *p = 42 }
    return x
}
```

An integer becomes a pointer only from a `uint64`, the width of an address;
casting an `int32` to a `Ptr<T>` is an error.

## Mixed-width arithmetic

Operators require both operands to have the same type. If you need to combine
values of different widths, widen the narrower one first:

```console
$ cat > src/main.kf << 'EOF'
fun main(): int32 {
    val a: int8 = 5
    val b: int32 = 7
    return a + b
}
EOF
$ komp check .
src/main.kf:4:12: error: operator operands must have the same type: `int8` and `int32`
        return a + b
               ^~~~~
```

The fix is an explicit cast:

```kflat
val a: int8 = 5
val b: int32 = 7
val sum = (a as int32) + b    // both int32
```
