# alloc

`alloc` is where the library keeps everything that produces owned storage.
`List<T>` is the growable, owning container: a value/move type — no refcount,
no implicit sharing. `val b = a` moves the list; to keep both, call
`.clone()`.

It also holds `String` itself, the text operations that build one (slicing,
trimming, case, splitting and joining), and `Path`, which wraps one. The division from `core`
is the allocator, not the subject: `core.text` answers what it can about a
string by looking at its bytes, and anything that has to produce storage for
its answer lives here.

Alloc's [`@prelude`](../lang/annotations.md#prelude) functions need no import:
`List` and `String` methods, splitting and joining, and so on — the same as
core's. Types and traits still resolve by name with no import at all.

## String

`String` is an owned, growable UTF-8 buffer. It is the language's string:
alloc marks it [`@lang("string")`](../lang/annotations.md#lang), so it is what
`${...}` produces, and what a string literal becomes where an owned string is
needed; a literal bound with no such use stays a `str`.

```kflat
var s = String.from("hello")
s.append(" world")
val len = s.len()
val view = s.as_str()     // str view, no copy
val copy = s.clone()      // deep copy
s.push_byte(33)           // one byte, no UTF-8 check
s.clear()                 // keeps the buffer
val empty = s.is_empty()
```

`String` implements `Drop` (frees the buffer), `Add` (`s1 + s2` produces a
new owned `String`), `Equal` (byte-level comparison), `Hash`, and `Display`.

```kflat
val greeting = String.from("hello") + String.from("! ")
println(greeting)    // "hello! "
```

Any `Display` value renders to a `String` with `display()` and no argument,
which is what `"${v}"` holds. A type that declares its own `display()` keeps
it:

```kflat
val n: uint64 = 42
val text = n.display()    // "42"
```

It is an ordinary struct, so you can implement your own traits for it:

```kflat
trait Shout { fun shout(): String }
impl Shout for String {
    fun shout(): String {
        var out = self.clone()
        out.append("!")
        return out
    }
}
```

The one thing you cannot do is declare another type called `String` in a
program that uses alloc: alloc's `String` would shadow it wherever the name is
written. Without alloc the name is free.

## List.new

`List.new<T>()` creates an empty list. The constructor is a `static` method:

```kflat
var xs = List.new<int32>()
```

No allocation happens until the first `push`. Without a type argument, the
list's uses supply one: `var xs = List.new()` followed by `xs.push(10)`
is a `List<int32>`, and so is one passed where a `List<int32>` is expected.
A list no use types is an error, naming both repairs.

## List literals

`[a, b, c]` is an array of its elements: `[1, 2, 3]` is an `int32[3]`, built
in place, with no allocation. It becomes a `List` where one is needed: in a
`List` slot, or bound without a type and then used as a list, say by `push`.
Its element type comes from the elements, or from the slot:

```kflat
val xs = [1, 2, 3]                   // int32[3]
var grows = [1, 2]
grows.push(3)                        // push is List's, so grows is a List<int32>
val wide: List<int64> = [1, 2]       // the slot's element type
total([10, 20])                      // total(xs: List<int32>)
```

Every element must have the literal's type: `[1, true]` is reported at `true`,
as "this element is `bool`, but the array holds `int32`". A slot may still ask
one type of them all, so `[[1, 2], [3]]` is fine where a `List<List<int32>>`
is expected.

An empty `[]` is typed like `List.new()`: by its slot, or by its uses.

```kflat
val none: List<uint8> = []
var later = []
later.push(7)                        // a List<int32>
```

A literal is not tied to `List`. Written where another type is expected, it
converts through that type's `From`: the array is handed to `from`, which is
how a `List` is built too. A string literal converts
through `From<str>` the same way. Only a literal converts; any other value
calls `from` itself. Where core's [`Array<T, N>`](core.md#array) is expected,
the literal builds the array in place, with exactly `N` elements. Your own
type opts in by implementing `From` over an array of any length:

```kflat
struct Bag {
    pub var total: int32
    pub var count: int32
}

impl<N: uint64> From<int32[N]> for Bag {
    static fun from(items: int32[N]): Bag {
        var bag = Bag { total: 0, count: 0 }
        while item in &items {
            bag.total = bag.total + item
            bag.count = bag.count + 1
        }
        return bag
    }
}

val bag: Bag = [4, 5, 6]             // total 15, count 3
```

A slot whose type does not implement `From<T[N]>` is reported as such.

## Adding and reading elements

`push` moves a value into the list. `get` returns a copy of an element, so it
exists only for a [`Copy`](../lang/memory.md#copy) element type:

```kflat
xs.push(10)
xs.push(20)
xs.push(30)

val first = xs.get(0)    // 10
val second = xs.get(1)   // 20
```

An element that owns memory, like `String`, is not `Copy`, and `get` on it is
an error. Borrow it with `at`, or clone the borrow for an owned copy:

```kflat
var names = List.new<String>()
names.push(String.from("alice"))
names.push(String.from("bob"))

val n: String = names.at(0).clone()   // owned copy
```

## Borrowing elements: at and at_mut

`at(i)` returns `&T`, a shared borrow into the list's buffer. The caller
reads without a copy:

```kflat
val first_len = names.at(0).len()      // borrow read, no copy
```

`at_mut(i)` returns `&var T`, a mutable borrow. The caller can mutate
the element in place:

```kflat
(*names.at_mut(0)).append("_updated")   // mutable borrow write
```

A field of the element is reachable the same way, and a mutating call on it
reaches the element's own field:

```kflat
holders.at_mut(0).tags.push(String.from("x"))
```

## Slices

A list lends its elements as a [slice](../lang/arrays.md#any-length-slices),
`&T[]`, wherever one is expected, so a function written once takes a list
or an array of any length:

```kflat
fun total(xs: &int32[]): int32 {
    var sum = 0
    while x in xs { sum = sum + x }
    return sum
}

fun main(): int32 {
    var xs = List.new<int32>()
    xs.push(10)
    xs.push(20)
    val fixed: int32[2] = [1, 2]
    return total(xs) + total(fixed)     // 30 + 3
}
```

`get`, `at`, `at_mut`, `set` and `xs[i]` all check the index, as an array's or
a slice's does, rather than reading or writing beyond the buffer. One past the
end of a three-element list stops with
`panic[index_out_of_bounds]: index 3 out of bounds for length 3` (see
[Faults](core.md#faults)). `remove(i)` answers `null` instead.

`as_slice()` and `as_slice_mut()` name the slices directly. While a slice of
a list is still used the list cannot grow or shrink, since that may move the
elements the slice points at.

## Indexing: `xs[i]`

`xs[i]` is sugar for `*(xs.index(i))`, the `Index` trait's shared accessor. It
**borrows**, exactly as `at(i)` does:

```kflat
val first = xs[0]                  // 10
val total = xs[0] + xs[2]
val n = names[k].len()             // no copy of the element
```

The borrow is the point: it reads any element type, where `get(i)` copies and
so reads only a `Copy` one.

Any type can be indexed by implementing `Index`:

```kflat
impl Index<uint64> for MyVec<T> {
    type Out = T
    fun index(k: uint64): &Self.Out { return self.at(k) }
}
```

`&Self.Out` rather than `&T` — an associated type is not currently resolved
behind a borrow, and the natural spelling is rejected.

### Indexing by more than one key

A type may implement `Index` at several key types. Each instantiation binds its
own `Out`, so an element read and a range read can return different things:

```kflat
impl Index<uint64> for MyVec<T> {
    type Out = T
    fun index(k: uint64): &Self.Out { return self.at(k) }
}

impl Index<Range<uint64>> for MyVec<T> {
    type Out = MyVec<T>
    fun index(k: Range<uint64>): &Self.Out { ... }
}
```

Which one `xs[k]` means follows from the type of `k`. `Self.Out` inside either
impl means that impl's own choice; written anywhere else, `MyVec.Out` names two
bindings and is rejected as ambiguous.

A range literal is typed by the slot it flows into, so the endpoints may be
written as literals:

```kflat
val one   = xs[0]
val front = xs[0..3]
val upto  = xs[0..=3]
```

`0..3` desugars to `range(0, 3, 1)`, and an integer literal with nothing to go
on is `int32` — so what makes this work is that the `Index<Range<uint64>>` impl
is found first and its key type then tells the literal what to be. The same
propagation reaches an ordinary parameter, so `total(0..4)` needs no `uint64`
locals either.

An annotation you write yourself still wins: `range<int32>(0, 3, 1)` in a
`Range<uint64>` slot is a mismatch to report, not a spelling to correct.

### Computed elements: `IndexValue`

`Index` lends an element, so only a type that stores its elements can
implement it: a bit in a bitset has no address to borrow. Such a type
implements `IndexValue` instead, which hands back the element itself, and
`bits[i]` is `bits.index_value(i)`:

```kflat
struct Bits {
    var words: List<uint64>
}

impl IndexValue<uint64> for Bits {
    type Out = bool
    fun index_value(k: uint64): bool {
        return ((self.words.get(k / 64) >> (k % 64)) & 1) == 1
    }
}

val set = bits[2]                  // a bool, not a borrow of one
```

A computed element has no place, so nothing can be written through it:
`bits[2] = true` is reported. A type implementing both `Index` and
`IndexValue` is rejected wherever it is indexed, since `[]` would have two
meanings.

### `xs[i] = v`

A store through a subscript is `*(xs.index_mut(i)) = v`, through `IndexMut`:

```kflat
xs[0] = 99
names[0] = String.from("carol")     // drops the old element
names[0] = names[1]                  // a copy: the two slots stay independent
```

The element it replaces is dropped after the store, and a right-hand side that
only borrows (another element, a field) is copied into the slot, so the short
spelling is as safe as `set`. The same holds for a store through any `&var`
reference, `*xs.at_mut(0) = v` included.

A subscript reads through `Index`, a shared borrow, and switches to
`IndexMut` wherever it is written through: a `mutating` method, a field store,
or an explicit `&var` borrow. The list itself then has to be a `var`.

```kflat
names[0].append("_updated")
holders[0].count = 3
bump(&var holders[0])
```

## Iteration

`while x in xs` iterates over the list by value. Each element is yielded as an
independently owned copy, so the source list stays intact:

```kflat
var total: int32 = 0
while x in xs {
    total = total + x
}
// xs is still alive and unchanged
```

For move-only elements (like `String`), each iteration value is a deep
clone. The source list owns its elements throughout the loop.

The binder carries its element type, so a generic function can be called on it
directly — `while x in xs { println(x) }` works, as does iterating a list of
structs that come from another crate.

For a move-only element, `while x in xs` clones and drops each element as it
goes. `while x in &xs` borrows them instead and costs nothing over an index
loop — see [Control flow](../lang/control-flow.md) for the measurement and for
what each binder lets you do.


## Growth and cost

The list grows by doubling its capacity when full, starting at capacity 4.
Reallocation copies existing elements. For move-only types, each element is
moved (not copied) during reallocation — the old buffer is freed after the
move.

`get` copies the element's bytes, which for a `Copy` element is the whole
value. `at` copies nothing. An owned copy of an element that is not `Copy` is
`xs.at(i).clone()`.

## Removing elements

`pop` drops the last element. Two more take it out instead:

```kflat
when (xs.take_last()) {          // moves the element OUT and shrinks
    Some(v) => use(v)
    None    => { }
}
xs.swap_remove(i)                // drops slot i, moves the last one into it
```

`take_last` is what lets one container drain another without cloning — a
rehash moves every entry into fresh buckets, and cloning them would copy
every key and value for nothing.

`swap_remove` does **not** keep order, and it cannot be built from the other
methods: `set(i, get(last))` needs `get`, which exists only for a `Copy`
element. A copy of an element that owns heap would share its buffer with the
slot, and `set` frees the buffer it overwrites.

An owning element is moved between slots with `swap`, which exchanges two
slots in place without dropping or cloning either one:

```kflat
xs.swap(i, j)                    // order-preserving; out of range is a no-op
```

To move a single element out of a slot rather than exchange two, borrow it
with `at_mut` and assign through the borrow — `*p = value` on a `&var T` is a
raw slot move, not a drop-and-replace.

## Searching, editing and sorting

`contains` and `index_of` need `Equal` on the element; `first` and `last` need
`Clone`; `sort` needs `Compare`. A `List<T>` whose element implements none of
them still has everything above — it only loses the questions that cannot be
asked of it.

```kflat
xs.contains(&2)              // bool
xs.index_of(&1)              // uint64? — the FIRST match
xs.last_index_of(&1)         // uint64? — the last
xs.first()                   // T? — a copy, None when empty
xs.last()                    // T? — a copy; take_last is the one that removes
```

These compare through `at`, the borrowing accessor, so they are safe for an
owning element where a search built out of `get` would not be.

Order-preserving edits, each O(n):

```kflat
xs.insert(i, v)              // shifts the rest right; past the end appends
xs.remove(i)                 // T? — hands the element back, shifts left
xs.reverse()                 // in place
xs.extend(other)             // drains `other`, moving its elements
xs.clear()                   // drops every element, keeps the buffer
```

`remove` is the order-preserving counterpart to `swap_remove`, which is O(1)
and does not keep order. Having only the second one is the surprising state,
so both are here and each says which it is.

`extend` takes `other` **by value** and drains it. Borrowing it instead would
mean copying every element — a `T: Clone` bound and an allocation per element
for an owning type — to leave behind a list the caller asked to merge away.

```kflat
ys.sort()                    // ascending, by the element's own Compare
ys.is_sorted()               // the postcondition, O(n)
```

Each of these is the list's [slice](core.md#algorithms) doing the work, so
a list sorts, searches and reverses as an array does, and has every other
slice algorithm too: `ys.sort_by_key(|p: &Person| p.age)`,
`ys.binary_search(&x)`, `ys.chunks(8)`. `sort` is stable: equal elements
come out in the order they went in. It moves elements only through `swap`,
so nothing is cloned or dropped, and it never allocates.

## Transforming text

Every one of these returns a fresh `String`, which is why they are here and
not in `core.text`:

```kflat
val stem  = name.substring(0, dot)
val clean = raw.trim()
val loud  = name.to_upper()
```

`replace` and `repeat` are not prelude — `import alloc.text_edit.*` first:

```kflat
val fixed = template.replace("{}", value)
val rule  = "-".repeat(40)
```

They are extensions on both `str` and `String`, so each is one declaration
callable either way — `raw.trim()` and `trim(raw)` name the same function —
and the `@prelude` forms need no import. Case conversion is **ASCII only** —
bytes outside `a-z`/`A-Z` pass through unchanged rather than being mangled —
and out-of-range slices clamp rather than fail.

The predicates that need no storage — `starts_with`, `index_of`, `is_blank` —
are in `core.text` instead, and `push(c)` appends a whole character. Of those,
only `is_blank` is not prelude.

## Splitting and joining text

These live here too, and for the same reason — the result is a `List`:

```kflat
val parts = "a,b,,c".split(",")        // ["a", "b", "", "c"]
val back  = str_join(&parts, ",")      // "a,b,,c"
val lines = source.lines()             // no trailing empty for a final \n
val words = "  the  quick ".split_whitespace()   // ["the", "quick"]
```

`split` and `join` are inverses, which decides the empty-piece question: the
piece count is always `count_of(sep) + 1` (`count_of` needs `import
core.text.*`), so adjacent separators and separators at either end produce
empty pieces and a round trip is exact.

`lines` goes the other way and drops the empty piece a trailing newline would
produce — a file ending in one has as many lines as it has newlines. It also
strips a `\r` before the `\n`.

`split_whitespace` collapses runs and drops the ends, which is the difference
from `split(" ")` and the reason to reach for it when parsing words.

Both `str` and `String` have them.

## Path

`Path` wraps an owned `String`, so it lives here rather than in core:

```kflat
val p    = Path.new("src/main.kf")
val dir  = p.parent()            // src
val name = p.file_name()         // main.kf
val next = dir.join("lib.kf")    // src/lib.kf
```

It preserves the spelling it was given; normalization and anything
platform-specific belong to `std.fs`.

## Deque

`Deque<T>`, from `alloc.deque`, is a growable ring buffer: pushing and
popping at either end is O(1) amortized, where `List.remove(0)` shifts every
element. It is the queue and the stack both, so there is no separate type for
either:

```kflat
import alloc.deque.*

fun main(): int32 {
    var queue = Deque.new<int32>()      // first in, first out
    queue.push_back(1)
    queue.push_back(2)
    val first = queue.pop_front()!!     // 1

    var stack = Deque.new<int32>()      // last in, first out
    stack.push_back(3)
    stack.push_back(4)
    val top = stack.pop_back()!!        // 4

    queue.push_front(0)                 // 0, 2
    return first + top + queue[1]       // 1 + 4 + 2
}
```

| method | does |
|---|---|
| `push_back(x)`, `push_front(x)` | the deque owns `x`, last or first |
| `pop_back()`, `pop_front()` | `T?`, moved out; null when empty |
| `front()`, `back()` | `T?`, a copy of an end; needs `Clone` |
| `at(i)`, `at_mut(i)`, `dq[i]` | a borrow of element `i` from the front; out of range panics |
| `size()`, `is_empty()`, `clear()` | as on a list |
| `iter()`, `while x in &dq` | front to back |

`iter()` is a [view](../lang/memory.md#view-types) of the buffer, so the
deque cannot change while a cursor from it is still used: a push could move
the buffer out from under it. Dropping a deque drops its elements; `clone()`
copies them in order.

## Arena

`Arena<T>`, from `alloc.arena`, owns values that live as long as it does and
are dropped together with it. `put` moves a value in and hands back a
`Ptr<T>` to it. The pointer stays valid until the arena is dropped, since
values sit in chunks that never move, so values can point at each other
freely:

```kflat
import alloc.arena.*

struct Node {
    val name: String
    val parent: Ptr<Node>?
}

fun main(): int32 {
    var nodes = Arena.new<Node>()
    val root = nodes.put(Node { name: String.from("root"), parent: null })
    val leaf = nodes.put(Node { name: String.from("leaf"), parent: root })
    val up = unsafe { (*leaf).parent!! }
    return unsafe { (*up).name.byte_len() } as int32 - 4    // 0
}
```

| method | does |
|---|---|
| `Arena.new<T>()` | an empty arena; nothing is allocated until the first `put` |
| `put(x)` | the arena owns `x`; a `Ptr<T>` to it |
| `size()`, `is_empty()` | how many values were put |

Dropping the arena drops every value in it, then frees its chunks. Nothing
is freed on its own: a value that must go before the others belongs in a
`Box`. A pointer from `put` must not be used once the arena is dropped,
which the compiler does not check. Chunks start at 16 values and double up
to 4096, so most `put`s allocate nothing.

## HashMap

A hash map keyed by anything implementing `Hash + Equal`:

```kflat
var ages = HashMap.new<String, int32>()
ages.insert(String.from("ada"), 36)

when (ages.get(&key)) {
    Some(n) => println(n)
    None    => println("absent")
}

ages.contains(&key)
ages.remove(&key)      // true if there was an entry
ages.size()
```

Written in KFlat with no compiler special-casing — an ordinary generic struct
over ordinary `List`s.

Storage is flat: every entry lives at an index in parallel `keys`/`vals`
arrays, and the bucket chains are indices rather than nested lists. That
allocates a handful of buffers for the whole map instead of one per bucket,
and a resize touches only the two index arrays — no key or value moves when
the map grows.

Iteration order is unspecified and changes on resize.

**Deriving a key type:** derive `Hash` *and* `Equal` together
([see core](core.md#hash)); the bound needs both, and they must agree.

**A note on `get`:** the value comes back as `V?`, and binding a
non-primitive payload needs a written type, because a generic `T?` loses its
payload type at the `when` binder:

```kflat
when (m.get(&key)) {
    Some(v) => { val got: String = v      // the annotation is required
                 println(got) }
    None    => { }
}
```

## AnnotatedFunction and AnnotatedItem

The entries of `annotated<A>()`: declarations carrying a
[declared annotation](../lang/annotations.md#declaring-an-annotation), and the
arguments each was given. A function-type target lists `AnnotatedFunction`,
a kind target `AnnotatedItem`.

```kflat
pub struct AnnotatedFunction<A, F> {
    pub val name: String        // the function's name as declared
    pub val module: String      // its module's path, `app.routes`
    pub val args: A             // the struct the annotation's parameters declare
    pub val function: F         // the target's function type
}

pub struct AnnotatedItem<A> {
    pub val name: String
    pub val module: String
    pub val kind: AnnotatedKind // Function, Struct, Enum or Trait
    pub val args: A
}
```

`AnnotatedKind` is `Copy` and `Equal`, so an entry's kind can be compared:
`entry.kind == AnnotatedKind.Trait`.
