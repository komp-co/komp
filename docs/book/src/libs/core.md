# core

`core` is the foundation library. It is always available — the compiler
injects it as an implicit dependency for any crate that does not declare its
own `core` dep. It defines the traits that operators and standard-library
facilities are built on, plus several primitive-alike types.

## Traits

Every operator trait lives in `core.traits`, one module per group:

| Module | Trait(s) | Operators |
|---|---|---|
| `core.traits.arith` | `Add`, `Sub`, `Mul`, `Div`, `Mod` | `+`, `-`, `*`, `/`, `%` |
| `core.traits.equal` | `Equal` | `==`, `!=` |
| `core.traits.compare` | `Compare` | `<`, `>`, `<=`, `>=` |
| `core.traits.bitwise` | `BitAnd`, `BitOr`, `BitXor`, `Shl`, `Shr` | `&`, `\|`, `^`, `<<`, `>>` |
| `core.traits.clone` | `Clone` | `.clone()` |
| `core.traits.drop` | `Drop` | Destructor |
| `core.traits.default` | `Default` | `.default()` |
| `core.traits.convert` | `From` | `T.from(x)` |
| `core.traits.call` | `Call0`-`Call3`, `CallMut0`-`CallMut3` | Lambda invocation |
| `core.traits.iter` | `Iterable`, `Iterator` | `while x in xs` |
| `core.traits.index` | `Index`, `IndexMut` | `a[i]` |
| `core.traits.from_elements` | `FromElements` | `[a, b, c]` in a slot of the type |
| `core.traits.try` | `Try`, `FromResidual` | postfix `?` |
| `core.display` | `Display` | `println`, string interpolation |

You do not import any of them. A trait resolves by name wherever it is
written, so implementing one takes no import at all:

```kflat
pub struct Point { pub val x: int32 }

impl Equal for Point {
    fun equals(other: &Point): bool { return self.x == other.x }
}
```

Free functions marked [`@prelude`](../lang/annotations.md#prelude) need no
import: `println`, `print`, `assert_eq`, `min`, `max` and `range` are written
directly, as are alloc's prelude functions. A function your own module defines,
or one you import, takes precedence over a prelude function of the same name. Everything else in `core` is `pub` but not ambient — reach
it by importing its module.


## Text: searching, slicing, and case

Text operations are **extensions** on `str` and `String`, so a literal and an
owned buffer behave alike. The common forms are `@prelude` and need no import;
the rest are imported from `core.text` and `alloc.text_edit`:

```kflat
if path.ends_with(".kf") { ... }   // no allocation
val stem  = name.substring(0, 6)   // a new String
val clean = raw.trim()
val loud  = name.to_upper()
```

Each of these is one declaration callable two ways — `path.ends_with(".kf")`
and `ends_with(path, ".kf")` name the same function. Use whichever reads
better at the call; the method form is the one this book uses.

The division is the allocator, not the alphabet. Answering without storage
lives in `core.text` (the forms marked with `_in`, `is_blank`, `last_index_of`
and `count_of` are not prelude and need `import core.text.*`):

| Method | Answers |
| --- | --- |
| `byte_len()`, `is_blank()`, `byte_at(i)` | size and single bytes |
| `starts_with(p)`, `ends_with(s)`, `contains(n)` | `bool` |
| `index_of(n)`, `last_index_of(n)` | `uint64?` |
| `count_of(n)` | how many non-overlapping occurrences |

Producing text needs an allocator, so it lives in `alloc`, each answering with
a new `String` (`repeat` and `replace` are not prelude and need
`import alloc.text_edit.*`):

| Method | Answers |
| --- | --- |
| `substring(a, b)`, `slice_from(a)`, `take_bytes(n)` | the bytes asked for |
| `trim()`, `trim_start()`, `trim_end()` | whitespace removed |
| `to_upper()`, `to_lower()` | ASCII case converted |
| `repeat(n)`, `replace(f, t)` | built from the input |
| `split(sep)`, `lines()`, `split_whitespace()` | a `List<String>` |

`split` and `join` are inverses, and `join` hangs off the list so the call
reads in the order the work happens:

```kflat
"a,b,c".split(",").join(";")    // "a;b;c"
```

### The `_in` forms, and why a loop wants them

A `str` is NUL-terminated and carries no length, so measuring one reads it.
Every search above therefore comes in a second form taking the length:

```kflat
s.starts_with(prefix)            // measures `s`, then searches
s.starts_with_in(n, prefix)      // for a caller that already knows `n`
```

`byte_at_in`, `is_blank_in`, `contains_in`, `count_of_in`, `index_of_from_in`,
`last_index_of_in` and `substring_in` are the same split.

You rarely write these directly — calling a method on a `String` uses them for
you, because a `String` stores its length and hands it over. They matter when
you are walking a `str` yourself, where the measuring form inside a loop makes
the loop quadratic:

```kflat
val n = s.byte_len()             // once
var i = 0
while i < n {
    val b = s.byte_at_in(n, i)   // not s.byte_at(i), which re-measures
    i = i + 1
}
```

A program that never needs owned text never reaches for the second table,
which is the point of the division: core stays usable without an allocator.

## Bytes and characters are different units

Every name says which unit it is in, because both exist and neither is the
default. The table above is **bytes**: for searching UTF-8 that is the right
unit — no encoded character is a suffix of another, so a byte match can only
land on a character boundary — and `byte_len` is not a character count.

```kflat
"héllo".byte_len()      // 6
"héllo".char_count()    // 5
```

Characters are the unit for counting, classifying and walking:

| Method | Answers |
| --- | --- |
| `chars()` | every character, in order |
| `char_count()` | how many characters |
| `char_at(i)` | the `i`-th CHARACTER |
| `decode_at(i)` | the character at a BYTE offset, and its width |
| `String.push(c)` | append a character, encoded |

```kflat
while c in s.chars() {
    if c == '/' { ... }
}
```

That reads as what it means, where `s.byte_at(i) == 47` does not. Walking with
`chars()` is one pass. `char_at(i)` is a **scan** — UTF-8 gives no way to find
the i-th character without decoding the ones before it — so a loop over
`char_at` is quadratic and `chars()` is what to reach for. `decode_at` is the
O(1) one and takes a byte offset, which is what `index_of` answers in.

There is deliberately no `s[i]`. A subscript reads as O(1) everywhere else,
and neither meaning works here: a byte offset can land inside a character, and
a character index would make the obvious loop quadratic.

A `char` is a Unicode **scalar**, not a character as a reader means one: an
accented letter may be one scalar or two, a flag emoji is two, a family emoji
several. Grapheme clustering and normalization are not offered.

Classification is ASCII only, and says so by answering `false` rather than
guessing:

```kflat
'7'.is_digit()      // true
'é'.is_alpha()      // false — a letter, but not an ASCII one
'é'.to_upper()      // 'é' — unchanged, rather than wrong
```

`is_digit`, `is_alpha`, `is_alnum`, `is_space`, `is_upper`, `is_lower`,
`to_upper`, `to_lower`, and `digit_value()`, which answers `uint32?` because
`'x'` has no value and any number would be one some caller believes.

Case conversion on whole strings is ASCII only for the same reason, so
`"é".to_upper()` is `"é"` and not half a character. Doing it properly needs
Unicode tables the library does not carry.

Out-of-range slices clamp rather than fail: `end` past the end means "to the
end", and a start at or past `end` gives `""`.

## UTF-8: bytes to characters

Everything above is byte-oriented, on purpose. `core.utf8` is the other half:
it turns bytes into Unicode scalars, and it is the only decoder in the tree —
the lexer's `char` literals go through it too.

```kflat
val d = s.decode_at(i)
d.scalar        // a char
d.width         // bytes consumed
d.well_formed   // whether those bytes were valid UTF-8
```

`chars()` is built on this and is what to use for a walk. Decoding by hand is
for a caller that already holds a byte offset — one that `index_of` gave it,
say — and wants the character there without walking from the start:

```kflat
when (s.index_of("=")) {
    Some(at) => { val after = s.decode_at(at + 1).scalar }
    None => { }
}
```

Note that `byte_len()` is itself a scan, because `str` is NUL-terminated. A
hand-written walk that asks for it on every character is quadratic in the
length; `chars()` measures once, which is the other reason to prefer it.

`width` is at least 1 at any offset inside the string, so a walk always makes
progress — a malformed byte is stepped over, not stalled on. It is 0 only past
the end, which the loop condition already excludes.

The offset is a **byte** offset, not a character index. That is what the rest
of the text API deals in (`index_of` answers in byte offsets) and it is the
only unit that makes decoding O(1).

`well_formed` is false for a stray continuation byte, a truncated sequence, an
overlong encoding, a surrogate, or a value past the last code point. When it
is false, `scalar` and `width` are still usable: the decoder reports rather
than substituting, so a caller can choose between inserting U+FFFD, reporting
an error, or carrying on with the raw byte.

A scalar is **not** a user-perceived character. `é` may be one scalar or two,
a flag emoji is two, and a family emoji is several. Grapheme clustering and
normalization are not offered.

### Encoding

`encode_utf8` is the inverse, and reports rather than substitutes:

```kflat
val e = c.encode_utf8()
e.width        // 1-4, or 0 if the scalar is not encodable
e.b0 … e.b3    // read `width` of them, in order
```

Four fixed bytes rather than a list, because an encoded scalar is never longer
than four and `core` has no allocator to reach for. `width` is 0 for a
surrogate or a value past the last code point — the two things a `char` can
hold that UTF-8 cannot represent.

It deliberately does not build a `String`, so the encoder stays usable where
there is no allocator at all. `String.push(c)` is the convenience on top, for
a caller that does have one.

## char

A `char` is a Unicode scalar. It has `Clone`, `Compare`, `Equal` and `Hash`,
and it prints:

```kflat
println('A')      // A
println('€')      // €
```

`display()` renders the **character**, not its number — `'é'.display()` is
`"é"`, two bytes. For the code point, convert: `('é' as uint32).display()` is
`"233"`. The conversions go both ways, so `65 as char` is `'A'`.

A scalar UTF-8 cannot encode renders as empty rather than as a replacement
character, so rendering never fails and never shows something the value did
not hold. Ask `encode_utf8` if you need to know.

> A `String` built byte-by-byte with `push_byte` must not contain an interior
> NUL. `String` is length-prefixed and `str` is NUL-terminated, so `as_str()`
> truncates there — which is why U+0000, a legal scalar, does not survive a
> round trip through a `str`.

## Hash

`Hash` is what lets a type be a key in [`alloc.HashMap`](alloc.md):

```kflat
pub trait Hash { fun hash(): uint64 }
```

Every primitive implements it, as do `str` and `String` — and the two agree,
so a `String` key and a `str` spelling of it find the same entry. Integers go
through a mixing step rather than answering themselves: a map takes its
bucket with `hash % n`, so an identity hash would put 0, 1, 2… into buckets
0, 1, 2…, which is the clustering the hash exists to avoid.

For your own types, derive it:

```kflat
@derive(Hash, Equal)
struct Point { pub var x: int32
               pub var y: int32 }
```

Derive **both**. `HashMap` bounds its key on `Hash + Equal`, and the contract
is that equal values hash equally — which holds by construction when the two
come from the same field list.

## Math

`core.math` needs no C library, so it is available to a freestanding
program. Most of it hangs off the value it acts on:

```kflat
(-7).abs()                  // 7, for any numeric type
(99).clamp(0, 10)           // 10
(-2.7).floor()              // -3.0
(2.5).round()               // 3.0
(0.0).lerp(10.0, 0.25)      // 2.5
(0.1 + 0.2).close_to(0.3, 0.000001)   // true
min<int32>(3, 7)            // 3
```

`abs` and `clamp` are generic over `Compare`, so one name covers every
numeric width. `min` and `max` stay free functions: they are symmetric in
their arguments, and `a.min(b)` would invent an asymmetry that is not there.
`round` takes halves **away from zero**, so `(-2.5).round()` is `-3.0` and
`(-x).round() == 0.0 - x.round()`. `(0.0).sign()` is `0.0`: zero has no
sign, and giving it one would invent information.

Each of these is an [extension function](../lang/extensions.md), so the free
form still works — `abs(-7)` and `clamp(99, 0, 10)` mean the same thing.

`close_to` exists because `0.1 + 0.2 == 0.3` is false. Comparing floats for
exact equality is almost never what you want.

### What a number is

Four traits name what the primitives have in common, so a generic function
can say it and reach it:

| trait | what it provides |
|---|---|
| `Zero`, `One` | `T.zero()` and `T.one()` — the identity a fold starts from |
| `Num` | `Add`, `Sub`, `Mul`, `Div`, `Zero`, `One`, as one name |
| `Bounded` | `T.min_value()`, `T.max_value()` |
| `Float` | `Num`, plus `T.pi()`, `T.e()`, `T.epsilon()` |

They are static methods because a constant is not something the language
has, and because a static method is what a bound can reach:

```kflat
fun <T: Num> Iterable<T>.total(): T {
    var acc = T.zero()
    while x in self {
        acc = acc + x
    }
    return acc
}
```

The same names work on a concrete type: `int32.max_value()`,
`float64.pi()`, `int32.zero()`.

`Num` carries the arithmetic and nothing else. Limits are a property of the
representation rather than of being a number — a big-integer type is a `Num`
with no largest value — so `Bounded` is separate, and a function that wants
both says `T: Num + Bounded`. `Float` does require `Num`, because a float is
a number:

```kflat
fun circle_area<T: Float>(r: T): T {
    return T.pi() * r * r
}
```

`sum` and `product` come from `Zero` and `One`, which is what lets them
answer for an empty iterable without a seed from the caller:

```kflat
(1..5).sum()        // 10
(2..5).product()    // 24
(3..3).sum()        // 0 — the additive identity
```

`core.math_hosted` is the half that calls libm, so it needs a C library:

```kflat
(16.0).sqrt()        // 4.0
(2.0).pow(10.0)      // 1024.0
float64.e().ln()     // 1.0 — natural log; log10 is the other one
(3.0).hypot(4.0)     // 5.0
float64.pi().to_degrees()    // 180.0
(1.0).atan2(-1.0)    // the angle of (-1, 1), quadrant resolved
```

These hang off the value they act on, like the rest of `core.math`. They used
to be free functions carrying an `_of` suffix — `sqrt_of`, `hypot_of` — which
existed only to keep the names free in a flat namespace. A receiver
disambiguates them, so the suffix went with the free function.

`atan2` takes y as the receiver, which keeps C's argument order: `y.atan2(x)`.

The names say which base they use, because silently being the wrong base is
a bad way to find out.

## Duration, Date, and DateTime

Time arithmetic is pure, so it lives here; reading a clock is
[`std.time`](std.md).

```kflat
val d = Duration.from_millis(1500)
d.as_seconds()      // 1  — truncates toward zero
d.as_seconds_f()    // 1.5
println(d)          // "1500ms"

val t = DateTime.from_unix(0)
println(t)          // "1970-01-01T00:00:00Z"
Date.of(2024, 2, 29).is_valid()      // true
Date.of(2023, 2, 29).is_valid()      // false
Date.of(2026, 12, 31).plus_days(1)   // 2027-01-01
```

`Duration` is **signed**: the useful operation is the difference between two
instants, and a difference can go either way.

Dates are **UTC**, and format as ISO 8601 with the `Z` spelled out. A local
time is a UTC instant plus a rule about where the reader is standing, and
those rules change several times a year; a timestamp without a zone is
ambiguous.

## Option and Result

`Option<T>` and `Result<T, E>` are enum types in `core`. Their interface is
the enum interface — construct with `Option.Some(x)` or `Option.None`, match
with `when`. `is_some()` and `is_none()` are provided as convenience
predicates.

An `Option` typed by its payload alone works — `val found = Option.Some(42)` is
an `Option<int32>` and matches with `when`. An annotation is still worth writing
where it makes the intent clearer:

```kflat
val found: Option<int32> = Option.Some(42)
if found.is_some() {
    when (found) {
        Some(v) => { println(v) }
        None => { }    // unreachable, but exhaustiveness required
    }
}
```

### Succeeding with no value

A fallible operation that has nothing to hand back says so with `void`:

```kflat
fun try_reserve(n: uint64): Result<void, AllocError> {
    if n > limit { return Result.Err(AllocError.OutOfMemory) }
    return Result.Ok()
}
```

A `void` payload is not a payload. `Ok` here is a variant with nothing in it,
so it is constructed `Result.Ok()` and matched `Ok =>` — the same as any
other payload-less variant. Writing `Result.Ok(x)` for it is an error, and so
is `Result.Ok()` where the payload is real.

This is what the `try_` family is written against. Without it the convention
would have to be `Result<bool, E>` with a `bool` that is always `true`.

This is not special to `Result`. `Option<void>` is presence carrying nothing,
and a generic body written against the payload still works: `is_some()` is
written `Some(_v) => true`, and at `void` the binder simply binds nothing,
because there is nothing to bind.

The one case left over is a binder that is genuinely *used* — `Full(v) => v`
at `Holder<void>`. There is no value for `v` to be, so the instantiation is
meaningless, and komp reports it from the C compiler rather than with a
diagnostic of its own. It cannot do better today: generic bodies are checked
once, abstractly, so nothing ever type-checks that body at `void`. In
practice the language stops you earlier anyway — a `void` parameter still
demands an argument you cannot produce, so such a method cannot be called.

`T?` is sugar for `Option<T>`. The return type `int32?` and `Option<int32>`
are interchangeable, and `val found: int32? = Option.Some(42)` works the same
way as the annotation above.

## Scope functions

Kotlin's scope functions, as extensions on every type. Each borrows its
receiver, so none copies it unless it says so:

| Call | Runs | Answers |
|---|---|---|
| `x.let(f)` | `f(&x)` | what `f` answers |
| `x.also(f)` | `f(&x)` | `&x` |
| `x.apply(f)` | `f(&var x)` | `&x`; `x` must be `var` |
| `x.take_if(f)` | `f(&x)` | a copy of `x` if `f` is true, else `None` |
| `x.take_unless(f)` | `f(&x)` | a copy of `x` if `f` is false, else `None` |

`take_if` and `take_unless` need `Clone`, since they hand back a copy. The
lambda's parameter type comes from the call, so it needs no annotation:

```kflat
struct Config {
    var verbose: bool
    var level: int32
}

fun main(): int32 {
    val name = String.from("komp")
    val length = name.let(|n| n.byte_len())                 // 4
    val short = name.take_if(|n| n.byte_len() < 3)          // None
    var cfg = Config { verbose: false, level: 0 }
    cfg.apply(|c| {
        c.verbose = true
        c.level = 3
    })
    val seen = cfg.also(|c| println("level ${c.level}")).level
    if short.is_some() { return 1 }
    return seen + (length as int32)                          // 7
}
```

`run` and `with` are left out: with borrowed receivers they say nothing
`let` does not. An extension of your own with one of these names shadows
core's in your crate.

## Range

`Range<T>` is what `a..b` produces: a range from `start` toward `end`,
advancing by `step`. It implements `Iterable<T>`, so a `while … in` loop walks
it like any other collection.

```kflat
val r = 0..4                 // Range<int32>, step 1
while v in r { ... }         // 0, 1, 2, 3
```

`T` is whatever the endpoints are, so `0..xs.size()` is a `Range<uint64>`.
Any `T` that is `Compare`, `Add`, `Sub` and `Mod` works — every numeric
primitive is.

`step` is a field rather than something the iterator derives. That is what
keeps `Range` generic without a `Step` trait: `core` supplies the arithmetic
for the primitives but nothing that produces *one* at a type parameter, so the
constructor takes it and the question never arises. `..` always passes `1`;
call `range(start, end, step)` directly, or use `.by()` below.

Writing `..` or `..=` imports the module for you, so `core.range` rarely
appears in a source file. A file that names `range` or `Range` itself still
needs `import core.range.*`.

### Inclusive: `a..=b`

`..` stops before `end`; `..=` includes it.

```kflat
while v in 0..4  { ... }     // 0, 1, 2, 3
while v in 0..=4 { ... }     // 0, 1, 2, 3, 4
```

`..=` is a single token, so `a..=b` is never read as an assignment. An
inclusive range is exact at the top of a type's range — `0..=255` over a
`uint8` terminates rather than wrapping — because the iterator asks whether
there is room for another step instead of taking one and comparing afterwards.

### Stride: `.by(k)`

```kflat
while v in (0..10).by(2)  { ... }    // 0, 2, 4, 6, 8
while v in (0..=10).by(5) { ... }    // 0, 5, 10
```

A step of zero describes no elements, so `.by(0)` yields an empty range rather
than panicking or looping forever.

### Direction: `.down()`

Direction is never inferred from the operands. `5..2` is empty, not reversed —
a range whose direction depended on runtime data would silently reverse
whenever `hi < lo`, and `0..0` would stop being safely empty. Counting down is
explicit:

```kflat
while v in (10..0).down()  { ... }   // 10, 9, 8, … 1
while v in (10..=0).down() { ... }   // 10, 9, 8, … 0
```

`down()` sets which way to travel; it does not swap the endpoints. So
`(0..10).down()` is empty.

### Reversal: `.rev()`

`.rev()` yields **the same elements in the opposite order**, which is not the
same as `down()` whenever the step does not divide the span:

```kflat
range(0, 10, 3)          // 0, 3, 6, 9
range(0, 10, 3).rev()    // 9, 6, 3, 0      — the same elements
range(10, 0, 3).down()   // 10, 7, 4, 1     — a different sequence
```

Reversal is exact rather than buffered: a range is a finite arithmetic
progression, so `rev()` computes the last element instead of iterating to it.
This is what an index walk wants — `(0..n).rev()` is `n-1 … 0` and is correct
at `n == 0`, where `(n - 1 ..= 0).down()` would underflow.

### Gaps: `.chain(other)`

Two ranges end to end, which is how discontinuous iteration is spelled:

```kflat
while v in (0..5).chain(8..10) { ... }   // 0, 1, 2, 3, 4, 8, 9
```

6 and 7 are absent because no segment covers them. A gap is described by what
the segments *are* rather than by a list of values to skip, which keeps it
exact for any step and direction — each segment keeps its own:

```kflat
while v in (0..10).by(5).chain(range_inclusive(20, 21, 1)) { ... }  // 0, 5, 20, 21
```

`chain` returns a [`Chain`](#chain), which is itself an iterator.

## Chain

`Chain<A, B, T>` runs two iterators end to end. `Range.chain` builds one, and
it can also be constructed directly over any two iterators — including another
`Chain`, which is how a third segment is reached:

```kflat
var three = Chain<Chain<RangeIter<int32>, RangeIter<int32>, int32>, RangeIter<int32>, int32> {
    first: (0..3).chain(8..10), second: (15..17).iter(), on_first: true
}
while v in three { ... }     // 0, 1, 2, 8, 9, 15, 16
```

The element type is a parameter rather than something derived from the bounds
on `A` and `B`. That is deliberate and temporary: a type parameter reachable
only through a bound is not substituted at the use site (#520), so the tidier
spelling compiles and then hands back an untyped element. For the same reason
`chain` takes a `Range<T>` rather than any `Iterable<T>`. When #520 is fixed,
`chain` widens and the nesting above gets a method form, without changing what
any existing caller wrote.

## ArrayIter

`ArrayIter<T>` is what an [array](../lang/arrays.md)'s `iter()` returns: a
cursor holding the address of the first element, the length and a position.
It implements `Iterator<T>` and `Iterable<T>`, and has `next_ptr()` for the
borrowing loop. It does not own the elements, so it is valid only while the
array is alive and unmoved.

## Path

`Path` represents a filesystem path. It wraps a `String`, so it lives in
`alloc` rather than core, and provides construction, component access, and
string conversion:

```kflat
val p = Path.new("src/main.kf")
val base = p.as_str()
```

## Raw pointers at the C boundary

`Ptr<T>` is the raw pointer, and `core.ptr` gives it the three operations an
`extern "C"` wrapper needs:

```kflat
import core.ptr.*

ptr_null<T>(): Ptr<T>              // the null pointer
ptr_is_null<T>(p: Ptr<T>): bool    // what C writes as `p == NULL`
ptr_as_option<T>(p: Ptr<T>): Ptr<T>?
```

`ptr_as_option` is the one to reach for at a boundary, because the obvious
transcription of a fallible C call is wrong:

```kflat
extern "C" fun try_alloc(n: uint64): Ptr<uint8>

val raw: Ptr<uint8>? = unsafe { try_alloc(n) }   // WRONG: Some(null) on failure
val raw = ptr_as_option(unsafe { try_alloc(n) }) // None on failure
```

`null` is the `None` literal, and `Option<Ptr<T>>` is a tagged struct rather
than a niche, so `Some(null)` is a distinct inhabitant from `None`. That is
the same answer Rust's `Option<*mut T>` gives and it is not a bug — but it
does mean a null pointer assigned into a `Ptr<T>?` reads as *present*, and
every `?:` and `is_none()` downstream agrees. The conversion has to be
written; it is not inferred.

## Where memory comes from

Every allocation a KFlat program makes goes through three functions:

```c
void* kf_alloc(size_t size);
void* kf_realloc(void* ptr, size_t size);
void  kf_free(void* ptr);
```

Generated code emits calls to them — `Box.new`, `alloc<T>`, `alloc_array<T>`
and the clone glue the compiler synthesizes for owning structs — and `core`
uses them for its own `String` storage too. Nothing allocates around them.

They are **weak**, so a program can replace them by defining its own and
listing the file in its manifest:

```toml
[native]
c_sources = ["native/my_alloc.c"]
```

```c
void* kf_alloc(size_t size)            { return bump_take(size); }
void* kf_realloc(void* p, size_t size) { return bump_grow(p, size); }
void  kf_free(void* p)                 { /* an arena frees all at once */ }
```

A strong definition anywhere in the link wins, so this needs no flag and no
change to how the project is built. That is the seam for a bump allocator, an
arena, a pool, or a fixed buffer on a target with no heap — and because
`core`'s own allocations go through it as well, a replacement sees all of
them rather than most of them.

### When there is no memory

The pair above is not where allocation actually happens. The **fallible**
operations are the primitives, and `kf_alloc` and `kf_realloc` are wrappers
over them:

```c
void* kf_try_alloc(size_t size);              // NULL when it cannot
void* kf_try_realloc(void* ptr, size_t size); // NULL when it cannot
void  kf_alloc_failed(size_t size);           // must not return
```

```c
void* kf_alloc(size_t size) {
    void* memory = kf_try_alloc(size);
    if (!memory) kf_alloc_failed(size);
    return memory;
}
```

That direction is the point. Two independently written halves drift, and the
one that drifts is always the fallible half, because it is the one nobody
exercises. Deriving one from the other means **replacing only
`kf_try_alloc` is enough** — the infallible path picks up your allocator and
your failure policy at once — while replacing `kf_alloc` outright still
works for a program that wants to.

`kf_alloc_failed` is where an infallible allocation ends up when there is no
memory. By default it panics, because a program that dies without printing
anything is indistinguishable from a crash. It is weak like the rest, so a
freestanding target can replace it with a fault handler, a reset, or a
blinking LED without touching the allocator. **It must not return**: every
`kf_alloc` result in `core` and in generated code is used without a check,
and that is only sound while failure cannot come back.

The fallible primitives return `NULL` rather than an `Option<Ptr<uint8>>`,
because that type is emitted as `Option__Ptr__uint8` — a tagged struct whose
layout comes out of komp's generic mangling — and hand-written C must not be
coupled to it. The KFlat side wraps the null with `ptr_as_option`, which is
what that function is for.

A `try_` surface on the containers themselves (`try_push`, `try_reserve`) is
not here yet: it waits on `unwrap` and postfix `?`, without which every
fallible call costs four lines at each layer.

### Which half lives where

`core`'s native code is in two files, and the seam runs between them:

| | `native/core.c` | `native/core_hosted.c` |
|---|---|---|
| listed under | `c_sources` | `hosted_c_sources` |
| includes | `<stdint.h>` `<stdbool.h>` `<stddef.h>` | `<stdio.h>` `<stdlib.h>` `<unistd.h>` `<sys/wait.h>` |
| defines | `kf_alloc`, `kf_realloc`, `kf_alloc_failed`, the primitive operators, the `String` vocabulary, argv storage | `kf_try_alloc`, `kf_try_realloc`, `kf_free`, `panic`, the print pair, number rendering, the test runner |

So the *derived* half of the allocation ABI is freestanding and the
*primitive* half is not — which is the right way round, because the
primitives are the ones a target replaces anyway. A
[freestanding](../start/projects.md#the-freestanding-tier) program gets the
first column and defines the second column's seams itself.

## assert

`assert`, `assert_eq` and `fail` are provided for tests (see
[Writing tests](../tools/testing.md)). On failure they print the label and
then panic, which ends the current test. Import `core.assert.*`.
