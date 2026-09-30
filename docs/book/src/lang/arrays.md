# Arrays

An array holds a fixed number of elements of one type, inline: in the local,
the field or the argument that holds it, with no allocation. The length is
part of the type, so `int32[3]` and `int32[4]` are different types.

```kflat
val xs: int32[3] = [1, 2, 3]
val ys: Array<int32, 3> = [4, 5, 6]   // the same type, spelled out
val zs: float64[] = [1.5, 2.5]        // float64[2]: the literal gives the length
```

`T[N]` and `Array<T, N>` are two spellings of one type. `N` is an integer
literal of at least 1. `T[]` leaves the length to the initializer, so it is
written only on a `val` or `var` initialized with an array literal or another
array; anywhere else the length must be written:

```console
error: an array type needs its length here, `T[N]`: `T[]` is for a `val` or `var` initialized with an array
    fun first(xs: int32[]): int32 {
                  ^~~~~
```

Suffixes read left to right: `int32[2][3]` is three `int32[2]`, `int32?[2]`
holds two options, and `int32[2]?` is an optional array.

## Literals

A list literal written where an array is expected builds the array in place,
with no allocation and no `push`. Its elements take the array's element type,
and there must be exactly as many as the array holds:

```console
error: this literal has 2 elements, but `int32[3]` holds 3
        val xs: int32[3] = [1, 2]
                           ^~~~~~
```

With no array expected, `[1, 2, 3]` is still a `List<int32>`; see
[alloc](../libs/alloc.md#list-literals). A crate without alloc has no list to
build, so there the same literal is an `int32[3]`, typed by its first element.

## Elements

`xs[i]` borrows element `i`, like a list's. The index is a `uint64`, checked
against the length on every access: an index past the end panics rather than
reading past the array. `size()` is the length, a constant.

```kflat
var grid: int32[2][2] = [[1, 2], [3, 4]]
grid[1][0] = 7
val corner = grid[1][0] + grid[0][0]     // 8
val count = grid.size()                  // 2
```

Writing through `xs[i]` needs `xs` to be a `var`, or a `&var` borrow of one.

## Loops

`while x in &xs` borrows each element in turn; `while x in xs` hands out
copies, deep ones when the element owns heap memory. `xs.iter()` is the cursor
both use, core's `ArrayIter<T>`, which points into the array and is valid only
while the array is alive and unmoved.

```kflat
fun total(xs: &int32[3]): int32 {
    var sum = 0
    while x in xs { sum = sum + x }
    return sum
}

fun fill(xs: &var int32[3], value: int32): void {
    while i in 0..xs.size() { xs[i] = value }
}
```

## Copying and moving

An array is Copy when its element is: assigning an `int32[3]` copies twelve
bytes, and a struct holding one can still be `@derive(Copy)`. An array of an
owning type, such as `String[2]`, moves like any owning value, and dropping it
drops each element in order.

Arrays go wherever a type does: in struct fields and enum payloads, as
generic arguments (`List<int32[2]>`, `Option<float64[3]>`), and across crates
in public signatures.

## What arrays do not do yet

An array implements no traits, so `==`, `Hash` and `Display` do not apply to
it, and `@derive(Equal)`, `Hash` and `Default` fail on a struct holding one;
`Clone` and `Copy` work. A
parameter takes an array of one length; a view of any length is a slice,
which KFlat does not have yet. [Limitations](../limitations.md#arrays)
tracks both.
