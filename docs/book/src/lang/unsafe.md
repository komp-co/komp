# unsafe, extern, and C interop

KFlat compiles to C. Calling C functions, allocating memory directly, and
working with raw pointers happens inside `unsafe` blocks.

## unsafe { }

Code inside `unsafe { ... }` can use operations the compiler would otherwise
reject: raw pointer arithmetic, calls to `extern "C"` functions that return
pointers, and intrinsics (`alloc_array`, `drop_in_place`, `ptr_read`). The block is an
expression, so it can be followed by ordinary postfix operations such as a
method call:

```kflat
fun main(): int32 {
    val p: Ptr<uint8> = unsafe { alloc_array<uint8>(16) }
    val i: uint64 = 0
    unsafe { *(p + i) = 255 }
    return 0
}
```

Pointer offsets accept integer literals and integer bindings, in decimal or
hex — `0xff` and `0b1010` both lex.

## Ptr, Box, and &

KFlat has three pointer-like types:

| Type | What it is | Ownership |
|---|---|---|
| `&T` | Shared borrow | Does not own; read-only |
| `&var T` | Mutable borrow | Does not own; read-write |
| `Box<T>` | Unique heap pointer | Owns the pointee — dropped when `Box` is |
| `Ptr<T>` | Opaque pointer | Raw C pointer — no ownership semantics |

`Box<T>` is the safe heap-allocated type. Creating one allocates, and when
the `Box` goes out of scope the pointee is dropped and the memory freed.

`Ptr<T>` is a raw, unsafe pointer. Dereferencing it or doing pointer
arithmetic requires `unsafe { }`:

```kflat
fun main(): int32 {
    val raw: Ptr<int32> = unsafe { alloc_array<int32>(1) }
    unsafe { *raw = 42 }
    val value: int32 = unsafe { *raw }
    return value
}
```

`Ptr<T>` carries no ownership information — the compiler does not insert
drops for it, nor does it track aliasing.

### From a pointer to a reference

A reference always points at a live value: a store through `&var T` drops the
value it overwrites. A raw pointer makes no such promise — memory from
`alloc<T>()` holds nothing until it is written — so a `Ptr<T>` is not accepted
where a reference is expected. Write `&*p` (or `&var *p`) inside `unsafe` to
say that it does point at a live value:

```kflat
struct Cell {
    pub var v: int32
}

fun bump(c: &var Cell): void {
    c.v = c.v + 1
}

fun main(): int32 {
    val p: Ptr<Cell> = unsafe { alloc<Cell>() }
    unsafe { *p = Cell { v: 1 } }      // a store through a pointer drops nothing
    bump(unsafe { &var *p })           // the value is live now
    return unsafe { (*p).v }
}
```

Passing `p` itself, `bump(p)`, is an error:

```console
$ komp check .
./src/main.kf:12:10: error: a raw pointer is not a reference: write `&var *p` inside `unsafe` to vouch that it points at a live value
        bump(p)
             ^
check: found errors
```

### A deref through a temporary

`unsafe` permits the dereference; it says nothing about how long the value
behind it lives. A call's result that is not bound to anything is freed at the
end of the statement, and a `Box` it owns goes with it. Reading out of that
box hands you a value whose parts are about to be freed:

```kflat
struct Node { pub var label: String }
struct Holder { pub var node: Box<Node> }

fun make(): Holder {
    return Holder { node: Box.new(Node { label: String.from("leaf") }) }
}

fun main(): int32 {
    val n = unsafe { *make().node }
    return n.label.byte_len() as int32
}
```

```console
$ komp check .
./src/main.kf:9:22: warning: `*` reads through a `Box` owned by a temporary, which is freed at the end of this statement; bind the call's result to a local first
        val n = unsafe { *make().node }
                         ^
```

The `deref_through_temporary` lint fires on `*f()` and `*f().field` when the
operand is a `Box` the call's result owns. The repair is to bind the result, so
it lives as long as the value read out of it:

```kflat
fun main(): int32 {
    val h = make()
    val n = unsafe { *h.node }
    return n.label.byte_len() as int32   // 4
}
```

A call that returns a borrow (`&T`) or a pointer owns nothing, so reading
through it is not reported.

## extern "C"

An `extern "C" fun` declaration imports a C function by name:

```kflat
extern "C" fun malloc(size: uint64): Ptr<uint8>
extern "C" fun free(p: Ptr<uint8>): void
extern "C" fun printf(fmt: str, value: int32): int32
```

Calling an `extern` function from safe code is allowed, but if the function
returns a raw pointer or does something unsafe, the caller is responsible for
wrapping it with `unsafe`.

## Native C sources

A crate can include C source files that are compiled and linked alongside
the generated C. List them in `kf.toml`:

```toml
[native]
c_sources = ["src/wrapper.c", "src/helper.c"]
```

These files are compiled by the C toolchain and linked into the final binary.
Any KFlat function declared `extern "C"` can be called from the C sources,
and the KFlat code can call `extern "C"` functions defined in them.

## alloc_array, drop_in_place and ptr_read

Three intrinsics are available in `unsafe` blocks for manual memory management:

- `alloc_array<T>(n)` returns a `Ptr<T>` to `n` uninitialized elements.
  The caller is responsible for initializing and eventually freeing them.

- `drop_in_place<T>(p)` calls the `Drop` implementation (if any) on the value
  at address `p`, then frees the memory. This is the building block for
  custom containers.

- `ptr_read<T>(p)` moves the value at `p` out: the bits are copied and the
  caller owns the result. The memory at `p` is left as it was, still holding
  the same bits, so the caller must overwrite it or stop treating it as
  owned. Otherwise the value is freed twice.

`*p` on a value that owns memory is a read through a borrow, like any other.
Moving it into an owned place makes a copy, which is safe but, inside a
container, is a leak waiting to happen: the original stays in the slot.
`ptr_read` is how a container moves an element instead. This swaps two
slots without copying either:

```kflat
fun main(): int32 {
    val p: Ptr<String> = unsafe { alloc_array<String>(2) }
    unsafe { *p = String.from("left") }
    unsafe { *(p + 1) = String.from("right") }
    val tmp = unsafe { ptr_read<String>(p) }
    unsafe { *p = ptr_read<String>(p + 1) }
    unsafe { *(p + 1) = tmp }
    val first = unsafe { ptr_read<String>(p) }
    val second = unsafe { ptr_read<String>(p + 1) }
    unsafe { dealloc<String>(p) }
    return (first.byte_len() * 10 + second.byte_len()) as int32   // 54
}
```

The intrinsics need no import. Their argument counts are checked like any
call's:

```console
$ komp check .
src/main.kf:2:34: error: wrong number of arguments to `alloc_array`: expected 1, found 0
```

Each names exactly one type, the one it works on:

```console
$ komp check .
src/main.kf:2:22: error: `alloc` takes one type argument, found 2
```

