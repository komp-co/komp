# Hello, world

The smallest KFlat program that outputs something:

```kflat
fun main(): void {
    println("Hello, world!")
}
```

Save this as `src/main.kf` inside a project directory (one with a `kf.toml`
— see [Projects and kf.toml](projects.md)). Then run it:

```console
$ komp run .
Hello, world!
```

`print` and `println` are built-in functions that write a value to standard
output; `println` adds a trailing newline. They accept strings, integers,
booleans, and any type that implements `Display`. The import is automatic.

## main

`main` can return either `void` or `int32`. If it returns `int32`, the value
becomes the process exit code:

```kflat
fun main(): int32 {
    return 0
}
```

A `void` main is equivalent to returning 0.

## komp run, komp build, komp check

| Command | What it does |
|---|---|
| `komp run <dir>` | Compile to C, build with cc, run the binary |
| `komp build <dir>` | Compile to C and build the binary (do not run) |
| `komp check <dir>` | Type-check only — no C output, no binary. Fastest feedback. |

`komp build` leaves the C output in `target/kflat/` so you can inspect it or
cross-compile it with your own C toolchain.

`komp check` works from the start — it reads the standard library's sources
until a build has written `target/kflat/*.kfi`, and the cached interfaces
after that.

## Reading a diagnostic

A type mismatch produces an error pointing to the offending expression:

```console
$ cat > src/main.kf << 'EOF'
fun main(): void {
    val x: int32 = "hello"
}
EOF
$ komp check .
src/main.kf:2:20: error: init type doesn't match declared
        val x: int32 = "hello"
                       ^~~~~~~
check: found errors
```

The diagnostic format is `file:line:column: severity: message`. The `^~~~`
underline marks the exact span of the problem. If you need machine-readable
output, use `--format=json`.

