# Memory: ownership, moves, borrows

KFlat's memory model is built on three principles: values are owned,
assignment moves, and `&`/`&var` create borrows. The model is a work in
progress — what follows describes what is implemented today, not the
end-state.

## Ownership and moves

Every value has exactly one owner at a time. Assigning a value to a new
binding **moves** it. The old binding is no longer usable:

```kflat
var a = String.from("hello")
val b = a                // a is moved — ownership transfers to b
// println(a)            // error: a is consumed
```

Structures containing move-only types (like `String` or `List`) are
themselves move-only: moving a struct moves every field.

The compiler tracks which variables are live. Using a variable after it has
been moved is detected and, for many common patterns, automatically repaired
with a deep clone:

```kflat
var h = Holder { name: String.from("orig") }
val h2 = h               // h is moved into h2
h.name.append("X")       // h is auto-cloned at this point of use
```

The auto-clone is deep: every field and nested structure is copied with its
own independent buffer. A warning tells you where the clone was inserted, so
you can add a `move` keyword or restructure the code to avoid the copy.

## Moves on branches and in matches

Only one branch of an `if` or `when` runs, so each branch may move the same
value. Nothing is copied unless the value is read after the branches join:

```kflat
struct Ticket { pub var id: String }

fun file(t: Ticket): void { }
fun archive(t: Ticket): void { }

fun route(t: Ticket, urgent: bool): void {
    if urgent {
        file(t)
    } else {
        archive(t)       // moves `t` too; no copy
    }
}
```

A `when` over a fresh value, such as a call's result, hands the payload to
its binder, which owns it. So `?:` moves an element out of a list:

```kflat
fun drain(queue: &var List<Ticket>, done: &var List<Ticket>): void {
    while !queue.is_empty() {
        val t = queue.take_last() ?: return
        done.push(t)     // `t` owns the ticket; no copy
    }
}
```

A `when` over a named value only views its payload: the value still owns
it, and moving a binder out copies it.

## The copy the compiler inserts for you

The same thing happens when a value is read *through a borrow* and handed to
something that takes it by value. The read cannot move the value — the
container still owns it — so the compiler copies instead:

```kflat
@derive(Clone)
pub struct Tag { pub var name: String }

fun length_of(t: Tag): uint64 { return t.name.byte_len() }

fun first_length(tags: &List<Tag>): uint64 {
    return length_of(*tags.at(0))
}
```

`Tag` allows the copy — the next section is what happens when a type does
not — so the compiler makes one and tells you where:

```text
main.kf:10:22: warning: auto-inserted a copy in `first_length` (arg 0 of `length_of`); borrow with `&` to avoid the copy
        return length_of(*tags.at(0))
                         ^
```

A `var` bound through a borrow is a copy for the same reason: it owns what
it holds, so changing it leaves the original alone.

```kflat
var f = *frames.at(0)              // a copy of the element
f.names.push(String.from("new"))   // frames[0] is unchanged
```

A `val` bound that way is a view instead, copied only where it is consumed.

## A copy needs your permission

That copy is correct, and it is also a decision nobody made. The type never
said it could be duplicated, and the site is one you did not write. So the
compiler asks first: it will only insert a copy into a type that implements
`Clone`.

```kflat
pub struct Unique { pub var name: String }

fun consume(u: Unique): uint64 { return u.name.byte_len() }
```

```text
main.kf:11:20: error: copying `Unique` here to fill arg 0 of `consume`, but it does not implement `Clone`; borrow with `&`, or write `@derive(Clone)` on it to allow the copy
        return consume(*xs.at(0)) as int32
                       ^
```

One line grants it, and it is the same line that makes the type satisfy a
`T: Clone` bound:

```kflat
@derive(Clone)
pub struct Shared { pub var name: String }
```

This is what lets a type be genuinely unique — a singleton, a unique buffer,
an owned handle. A type that says nothing cannot be duplicated behind your
back, which until this rule existed was not something KFlat could express at
any price.

### In generic code

A generic function cannot know whether its `T` allows copying, so it has to
say so. A copy of a `T` read through a borrow needs `T: Clone` (a deep copy)
or `T: Copy` (a byte copy) in the signature:

```kflat
fun first_of<T>(xs: &List<T>): T {
    return *xs.at(0)
}
```

```text
main.kf:2:12: error: copying `T` here to fill arg 0 of `<return>`, but it does not implement `Clone`; borrow with `&`, or bound it: `T: Clone`
        return *xs.at(0)
               ^
```

With `fun first_of<T: Clone>`, it compiles, and a caller whose element type
has no `Clone` is told so at its own call, as an unmet bound.

The refusal is the `unauthorized_copy` lint. Downgrading it restores the older
behaviour exactly — the copy was always going to be inserted; what changes is
whether you are told to approve it:

```sh
komp build -W unauthorized_copy   # warn and copy anyway
komp build -A unauthorized_copy   # copy silently, as older komp did
```

## Levels for the copies you did allow

A copy into a type that *does* implement `Clone` is the `implicit_copy` lint,
and like any lint it has a level:

```sh
komp build -D implicit_copy      # make every inserted copy an error
komp build -A implicit_copy      # accept them silently
```

`@allow(implicit_copy)` on a declaration sets the same thing for what it
encloses, and wins over the flag. It is what an accessor wants when it has to
return an owned value and so cannot take the advice:

```kflat
@allow(implicit_copy)
fun read_twice(tags: &List<Tag>): uint64 {
    return length_of(*tags.at(0)) + length_of(*tags.at(0))
}
```

Its sibling `copy_after_move` covers the other case — a value used again after
it was moved, where the compiler copies the earlier move so the original stays
readable. That is the warning the section above mentions.

A `[lint]` table in `kf.toml` sets levels for a whole crate and reaches these
two the same way the flag and the annotation do: komp reads the table and
hands each row to the compiler, so all three sources arrive together, on
`komp build` as on `komp check`.

Be aware that a copy is a copy: `implicit_copy` firing in a loop is the
difference between an algorithm that is linear and one that is not.

## Borrows: & and &var

A borrow lets you refer to a value without taking ownership. The original
owner keeps the value and remains responsible for dropping it:

```kflat
var xs = List.new<int32>()
xs.push(1)
xs.push(2)

val b = &xs               // shared borrow — b refers to xs
val n = b.size()          // method call through the borrow
val d = (*b).size()       // explicit dereference

var ys = List.new<int32>()
val m = &var ys           // mutable borrow
(*m).push(9)              // write through the mutable borrow
```

A shared borrow (`&T`) gives read-only access. A mutable borrow (`&var T`)
allows writes through the borrow. Borrowing does not consume the owner — the
variable that was borrowed from is still usable afterwards:

```kflat
xs.push(4)                // still alive
```

Passing a `&T` to a function takes the borrow. Inside the function, `self` is
the borrowed value:

```kflat
fun sum_through(b: &List<int32>): int32 {
    var total: int32 = 0
    var i: uint64 = 0
    while i < (*b).size() {
        total = total + (*b).get(i)
        i = i + 1
    }
    return total
}
```

## clone()

The `Clone` trait provides an explicit deep copy. Call `clone()` on any value
whose type implements `Clone`:

```kflat
var s = String.from("abc")
val s2 = s.clone()        // deep copy — independent buffer
s.append("d")
// s2 is still "abc", unaffected by the mutation
```

The compiler knows how to deep-copy any type — it synthesizes that alongside
the drop glue — so `value.clone()` written by hand still works on a struct
that derives nothing. What `@derive(Clone)` adds is the type's own statement
that copying it is allowed, and that is what two things consult: a `T: Clone`
bound, and the copies the compiler would otherwise insert for you without
asking.

## Copy

A `Copy` type is duplicated by copying its bytes. Reading one out of a place
leaves the place intact and gives you an independent value, which is what
makes handing it around by value free and safe:

```kflat
@derive(Copy)
struct Point { pub var x: int32, pub var y: int32 }

fun shifted(p: Point): Point {
    var q = p
    q.x = q.x + 1
    return q               // `p` is untouched
}
```

Every primitive is `Copy`, and so is `Option<T>` or `Result<T, E>` over
`Copy` payloads. A type opts in with `@derive(Copy)`, which also supplies the
`Clone` impl `Copy` requires unless you derive or write one yourself.

Being `Copy` is a promise that nothing in the value owns memory, so the
compiler checks it wherever it is made — derived or written by hand:

- every field must itself be `Copy`. A `Ptr<T>` or a `&T` is; a `String`,
  a `Box<T>`, a `List<T>` or a `&var T` is not.
- the type must not implement `Drop`, because two copies would run the
  destructor twice.

```console
error: `Named` cannot be Copy: field `label` is not Copy
```

A generic function asks for it with a bound, `<T: Copy>`.

## Drop

The `Drop` trait provides a destructor. Its `drop()` method runs when a
value's scope ends:

```kflat

extern "C" fun free(p: Ptr<uint8>): void

struct Owned {
    var data: Ptr<uint8>
}

impl Drop for Owned {
    fun drop(): void {
        unsafe { free(self.data) }
    }
}
```

`free` is C's, not a KFlat builtin — it has to be declared as an `extern "C"`
before you can call it.

When a `Drop`-implementing value goes out of scope, `drop()` is called before
any field-by-field cleanup. For a struct containing a `Drop` field, the
compiler generates glue that calls each field's `drop` in declaration order.

## Borrows are not storable

A borrow is only valid for as long as what it borrows from, so it may not be
written into a declaration that outlives the call which produced it. Struct
fields and enum payloads are rejected:

```kflat
struct Holder {
    val name: str          // error: a borrow is not storable
    val count: &int32      // error
}

enum Held {
    Text(str)              // error
}
```

`str` counts as a borrow — it points at bytes something else owns. Store a
`String` instead, which owns its buffer.

A borrow reached through a container is stored just as plainly, so the rule
looks all the way through the type:

```kflat
struct Holder {
    val views: List<str>            // error
    val maybe: Option<&int32>       // error
    val boxed: Box<str>             // error
    val names: List<String>         // fine — the elements are owned
}
```

`Ptr<T>` is the one exception, wherever it appears: raw pointers are the
`unsafe` escape hatch, and `List<Ptr<str>>` is accepted on those terms.

Passing a borrow **into** a function is unaffected, and that is the point:

```kflat
fun width(text: str): uint64 { ... }        // fine
fun bump(slot: &var int32): void { ... }    // fine
fun read(value: &dyn Score): int32 { ... }  // fine
```

A `String` passed where a `str` is expected lends its text for the call.
When the callee keeps the value instead, as a list keeps an element, the
text must outlive the statement, and a temporary `String` does not:

```kflat
var names = ["T"]
names.push(String.from("hello"))    // error
val kept = String.from("hello")
names.push(kept)                    // fine: `kept` outlives the statement
```

```console
error: `push` keeps this `str`, which points into a `String` freed at the end of the statement; keep the `String` in a local first, or store `String`s
```

The same holds for any parameter typed by a type parameter that stands for
`str`, whose argument a generic function or method may store.

## View types

A `view struct` or `view enum` is a borrow of your own design. Its fields may
hold borrows, which no other struct may, and in exchange its values follow the
rules of `&T`:

```kflat
view struct Window {
    val text: str
    val from: uint64
}

impl Window {
    fun length(): uint64 { return self.text.byte_len() - self.from }
}

struct Text {
    var bytes: String
}

impl Text {
    fun window(from: uint64): Window { return Window { text: self.bytes.as_str(), from: from } }
}
```

`view` is a word only before `struct` or `enum`, so a binding named `view`
elsewhere is untouched. `pub view struct` exports one.

`text.window(1)` borrows from `text`, as `text.bytes.as_str()` would, and
everything below applies to it unchanged: a view cannot be stored in a struct
that is not itself a view, it freezes what it borrows while it is used, it
cannot be returned past its origin, and a stored lambda cannot capture it.

```kflat
struct Holder {
    val window: Window     // error: it is a view, and a view is only valid
}                          //        for the call that made it
```

A view built in place borrows what its fields were lent, so
`Window { text: owned.as_str(), from: 0 }` freezes `owned` like the method
does. A view borrows from one place: fields lent from two different bindings
are rejected, since freezing either one would leave the other free.

```kflat
view struct Pair {
    val a: str
    val b: str
}

val p = Pair { a: x.as_str(), b: y.as_str() }   // error: borrows from both `x` and `y`
val q = Pair { a: x.as_str(), b: x.as_str() }   // fine: one place
```

A view holding another view borrows what the inner one does. An instance of a
generic view, such as `Cursor<int32>` from
`view struct Cursor<T> { val first: &T }`, is a view too, and a view keeps
being one in another crate. Core's [slices](arrays.md#any-length-slices),
`&T[]` and `&var T[]`, are views written this way.

A `val` field holding a `&var` cannot be pointed elsewhere, but a `mutating`
call through it changes what it borrows. It still needs a writable view: from
a method that is not `mutating`, it is rejected.

```kflat
struct Sink {
    var items: List<int32>
}

impl Sink {
    mutating fun emit(x: int32): void { self.items.push(x) }
}

view struct Ctx {
    val sink: &var Sink
}

impl Ctx {
    mutating fun report(x: int32): void { self.sink.emit(x) }
}
```

## Returning a borrow

A function may return a borrow, and where it comes from is never written
down — it is read off the signature. An instance method borrows from `self`;
otherwise the one parameter that is a borrow:

```kflat
impl String {
    pub fun as_str(): str          // borrows self
}

fun longest_word(text: str): str   // borrows text
```

With no borrow parameter at all, the returned borrow is **static** — it can
only have come from a literal, which outlives every caller:

```kflat
fun version(): str { return "0.1.0" }      // fine
```

With *two* candidates there is no way to say which, and no syntax to say it
in, so the signature is rejected. Return an owned value or an index instead:

```kflat
fun pick(a: &Value, b: &Value): &Value     // error: which one is the origin?
```

What a returned borrow may not do is read out of a binding the function owns,
because that binding is dropped at the return:

```kflat
fun built(): str {
    val owned = String.from("abc")
    return owned.as_str()          // error: `owned` is dropped at the return
}
```

A local that is itself a borrow is fine — its origin is elsewhere:

```kflat
fun forwarded(text: str): str {
    val same = text
    return same                    // fine
}
```

## A borrow freezes what it borrows

A local bound to a borrow of another local carries that local as its
**origin**. While the borrow is live, the origin may not be changed:

```kflat
var out = String.from("a")
val view = out.as_str()        // view borrows out
out.append("b")                // error: may reallocate; view would dangle
if view == "a" { ... }
```

A call's result has the origin of the one argument it was lent, the receiver
of an extension included, so `first_word(&out)` and `out.peek()` (for
`fun String.peek(): str`) borrow `out` just as `out.as_str()` does.

A borrow bound to another borrow keeps the first one's origin: after
`val b = a` where `a` borrows `out`, `out` stays frozen for as long as `b` is
used.

Reassigning the origin is rejected for the same reason — it drops the buffer
outright rather than moving it.

"While the borrow is live" means from its binding to its **last use**, not the
whole scope. Once nothing reads the borrow again, the origin is free:

```kflat
var out = String.from("a")
val view = out.as_str()
if view == "a" { ... }         // last use of view
out.append("b")                // fine
```

Reading the origin is not changing it, so a non-`mutating` method on it is
always allowed while a borrow is live.

Handing the origin **away** is rejected on the same terms. Giving it to a
parameter that takes it by value makes the callee responsible for dropping it,
while the borrow is still being read:

```kflat
fun consume(s: String): uint64 { ... }
fun observe(s: &String): uint64 { ... }

val view = text.as_str()
consume(text)                  // error: `text` cannot be moved here
observe(&text)                 // fine — lending it takes nothing away
if view == "hello" { ... }
```

And a borrow of a local cannot be returned, however many bindings it passes
through on the way out:

```kflat
fun leaked(): str {
    var text = String.from("hello")
    val view = text.as_str()
    return view                // error: `view` borrows `text`, dropped here
}
```

Returning a *value* computed from a borrow is fine — nothing points at the
origin afterwards:

```kflat
return String.from(view).len()  // fine
```

## One call, one mutable lending

A single call may not be handed the same place twice when either handing is
mutable. The callee gets two references and is entitled to treat them as
independent; writing through one while reading the other is where aliasing
corruption comes from.

```kflat
edit_both(&var p.left, &var p.right)   // fine — different fields
read_both(&p.left, &p.left)            // fine — neither is mutable
edit_both(&var p.left, &var p.left)    // error: lent mutably twice
edit_and_read(&var p.left, &p.left)    // error: written and read at once
edit_pair(&var p, &p.left)             // error: `p` contains `p.left`
```

Overlap is containment over the access path, so `p.left` conflicts with `p`
and with itself, but not with `p.right`. A borrow reached through a method
belongs to the receiver, and the index is not carried, so two elements of one
container conflict:

```kflat
edit_and_read(xs.at_mut(0), xs.at(1))  // error: both are `xs`
```

Proving the indices differ is not attempted. Sequence the two accesses
instead.

The receiver is not counted, so `out.append(out.as_str())` is allowed —
`String.append` supports an aliased source deliberately. The check is on the
declared arguments only.

## What is not checked today

Dropping the origin early is not yet rejected.

Containers hold borrows only outside storage: `List<&T>` and `Option<&T>` are
rejected in a field or an enum payload, but a local or a parameter of that
type compiles, and whether an element outlives its origin is not tracked.

The rule for programmers until then: do not keep a borrow past where the
owner is alive.
