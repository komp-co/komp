# Primitive types and literals

KFlat's primitive types have exact, platform-independent widths.

## Integers

| Type | Width | Signed | Range |
|---|---|---|---|
| `int8` | 8 bits | signed | -128..127 |
| `int16` | 16 bits | signed | -32,768..32,767 |
| `int32` | 32 bits | signed | -2^31..2^31-1 |
| `int64` | 64 bits | signed | -2^63..2^63-1 |
| `uint8` | 8 bits | unsigned | 0..255 |
| `uint16` | 16 bits | unsigned | 0..65,535 |
| `uint32` | 32 bits | unsigned | 0..2^32-1 |
| `uint64` | 64 bits | unsigned | 0..2^64-1 |

Widths are exact: an `int8` is one byte on every target. The compiler rejects
an out-of-range initializer:

```kflat
val a: int8 = 127    // ok
val b: int8 = 128    // type error
```

The spellings in the table are the primitive type names. Short names such as
`i32` and `u32` are ordinary identifiers, not aliases; a program may declare
its own types with those names.

Integer literals without a type annotation default to `int32`. If you need
another width, annotate:

```kflat
val small: int8 = 3
val big: int64 = 5000000000
```

A signed integer can be cast to a wider type with `as`:

```kflat
val x: int8 = 7
val y: int16 = 100
val w = (x as int32) + (y as int32)   // widen before arithmetic
```

Decimal, hexadecimal (`0xff`), binary (`0b1010`) and octal all lex, and `_`
groups digits without carrying value, so `1_000_000` reads as one number.

Every integer width has a `Display` impl, `int64` included, so any of them can
be printed or interpolated directly.

## Floating-point

`float32` and `float64` are IEEE 754 single and double precision. Arithmetic
and comparison work through the operator traits just like integers do.

`3.14` lexes as a float literal, and so does exponent notation: `e` or `E`,
an optional sign, then digits. A number with an exponent is a float even
without a fraction, so `1e10` is ten billion, not the integer `1` beside a
name:

```kflat
val pi = 3.14
val avogadro = 6.022e23
val tolerance = 1e-9
val third = (1 as float64) / (3 as float64)
```

Both float types have a `Display` impl, so a float can be printed or
interpolated. It shows the fewest digits that read back as the same value —
`0.1` for 0.1, and `0.30000000000000004` for `0.1 + 0.2`, which is exact rather
than tidy.

## bool

`bool` has two values: `true` and `false`. It is a single byte, not an alias
for an integer. `if`, `while`, and `when` require a `bool` condition.

```kflat
val flag = true
val ready = false
```

## char

`char` is a 32-bit Unicode code point. Comparison and equality work on it.

A character literal is written in single quotes, escapes included:

```kflat
val a: char = 'A'
val newline = '\n'
val is_b = a == 'B'
```

### Escapes

String and character literals share one escape language, and komp decodes it
— it is not passed through to the C compiler.

| Escape | Byte | |
|---|---|---|
| `\a` | 7 | bell |
| `\b` | 8 | backspace |
| `\f` | 12 | form feed |
| `\n` | 10 | newline |
| `\r` | 13 | carriage return |
| `\t` | 9 | tab |
| `\v` | 11 | vertical tab |
| `\\` `\'` `\"` | | the backslash and the delimiters |
| `\$` | 36 | a literal `${`, so interpolation can be escaped |
| `\NNN` | | octal, one to three digits, at most 255 |
| `\xNN` | | hex, **exactly** two digits |

Anything else is an error. Both numeric forms are bounded, which is the point:
C's `\x` is greedy over hex digits, so in C `"\x41B"` is a single escape and
one byte. Here it is `A` followed by `B`:

```kflat
"\x41B".byte_len()     // 2
"\101".byte_len()      // 1 — octal for `A`
'\x41' == 'A'          // true
```

`\0` is not a special case; it is the one-digit octal escape. Note that an
embedded NUL does not currently survive `String.from`, which measures with
`strlen`.

A `"""triple-quoted"""` literal is raw: no escape is interpreted, a backslash
is a backslash, and newlines are content.

## str and String

KFlat has two text types:

| Type | What it is | Where it lives |
|---|---|---|
| `str` | A borrowed, immutable view of UTF-8 bytes | Points into memory owned elsewhere |
| `String` | An owned, growable UTF-8 buffer | Heap-allocated, managed by the compiler |

### A literal chooses its type; a value does not

A string literal fills either slot, with nothing written at the call site:

```kflat
val v: str = "hello"
val s: String = "hello"
```

Nothing is converted there. The slot chooses the literal's representation, the
same way it chooses an integer literal's width:

```kflat
val small: uint8 = 7
val wide:  int64 = 7
```

A `str` **value** is a different matter. Making a `String` of one copies the
text onto the heap, so it is written where it happens:

```kflat
val view: str = "hello"
val owned: String = String.from(view)   // the copy is visible
```

Leaving it out is an error rather than a silent allocation:

```console
$ komp check .
./src/main.kf:5:18: error: a `str` value does not become a `String` on its own — the conversion copies the text onto the heap, so write `String.from(...)`
    return greet(view) as int32
                 ^~~~
check: found errors
```

The other direction stays implicit, because it copies nothing — a `String` is
usable wherever a `str` is wanted:

```kflat
fun width(s: str): uint64 { return s.byte_len() }

val big = String.from("hello")
val n = width(big)      // no call written, and nothing is copied
```

### Ownership and cost

`String` owns its buffer and frees it when it goes out of scope. `str` is a
borrowed, NUL-terminated pointer into a buffer it does not own — it is valid
only as long as the `String` or other source is alive.

A `str` carries no length, so `byte_len()` on one walks to the terminator.
`String` stores its length and answers in constant time.

`String` is alloc's type, marked [`@lang("string")`](annotations.md#lang), and
that marker is what makes it the language's string. In a program without
alloc there is no owned string: a bare literal stays `str`, and `String` is an
ordinary name you may give a type of your own.

### String interpolation

A `$` inside a string introduces a slot that holds any expression:

```kflat
val name = String.from("world")
val n: int32 = 3
println("hello ${name}, ${n} times")   // "hello world, 3 times"
```

The compiler expands the string into owned pieces joined with `+`: each
literal part becomes `String.from("...")` and each slot becomes
`String.of(&(expr))`, which renders the value through `Display`. Every
interpolated expression must implement `Display`, and the slot only borrows
it, so the value is still usable afterwards.

Interpolation builds a `String`, so it needs alloc. Without it, each slot is
an error saying so:

```console
$ komp check .
./src/main.kf:3:21: error: string interpolation builds an owned string, which needs `alloc`: add it to the dependencies
        val s = "n is ${n}"
                        ^
check: found errors
```

To get a literal dollar sign, escape it: `\$`.

### Multi-line strings

Triple-quoted strings span multiple lines. Newlines are content and no escape
sequence is interpreted — a backslash is a backslash:

```kflat
val verse = """Line one
Line two
Line three"""
```

Four quotes end the literal (three end it, so a leading quote belongs to the
string):

```kflat
val quoted = """say "hi""""
```

Slots work here too, exactly as in the single-line form:

```kflat
val who = "world"
val greet = """hello ${who}
and "quotes" need no escape"""
```

`${` is the one thing raw does not cover, because it is kf's own syntax rather
than the string's. So `\$` means a literal dollar, in both forms and whether or
not another slot opens.

