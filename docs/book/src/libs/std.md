# std

`std` provides filesystem, environment, input, stream, process and time utilities. Its modules
are independent — import what you need.

## Using std

A program that runs on an operating system has `std` without naming it in
`kf.toml`: importing from it is enough.

```kflat
import std.io.eprintln

fun main(): int32 {
    eprintln(&"to stderr")
    return 0
}
```

komp compiles `std` only for the crates that import it, so a program that
never does pays nothing for it. The `std` is always the one bundled with the
compiler; an explicit `std = { path = ... }` entry still works, and is not
needed.

A [freestanding](../start/projects.md#the-freestanding-tier) program has no
`std`: processes, files and streams need an operating system. A crate of one
that imports `std`, or names it, is an error that says so.

## std.fs

Reading and writing files, and the filesystem around them. The operations
that can fail answer a `Result`, whose error names the path and the operating
system's reason, so a missing file is not mistaken for an empty one:

```kflat
import std.fs.read_to_string
import std.fs.write_text

fun main(): int32 {
    when write_text("notes.txt", "first line\n") {
        Ok(_) => {}
        Err(error) => {
            println("cannot write: ${error}")
            return 1
        }
    }
    val text = read_to_string("notes.txt").unwrap()
    println(text.as_str())

    when read_to_string("missing.txt") {
        Ok(_) => println("unexpected")
        Err(error) => println("${error}")
    }
    return 0
}
```

```console
first line

missing.txt: No such file or directory
```

| Function | Return | Notes |
|---|---|---|
| `read_to_string(path: str)` | `Result<String, IoError>` | The whole file |
| `write_text(path: str, contents: str)` | `Result<void, IoError>` | Creates or truncates |
| `remove_file(path: str)` | `Result<void, IoError>` | |
| `remove_dir_all(path: str)` | `Result<void, IoError>` | A directory and everything under it |
| `rename_path(from: str, to: str)` | `Result<void, IoError>` | Replaces `to` if it exists |
| `exists(path: str)` | `bool` | |
| `is_file(path: str)` | `bool` | A regular file |
| `is_directory(path: str)` | `bool` | |
| `read_dir(path: str)` | `Result<List<String>, IoError>` | Entry names, sorted, without `.` and `..` |
| `create_dir_all(Path)` | `bool` | `true` on success; creates parents |
| `TempDir.new(str)` | `TempDir` | Drops on scope exit — deletes the directory |

`IoError` has `path`, `code` (the `errno` value) and `message`, and displays
as `path: message`. `Path` is in `alloc.path`, not `std.fs`; import it
separately.

## std.env

| Function | Return |
|---|---|
| `current_dir()` | `Path` — the process's working directory |
| `env_var(name: str)` | `String?` — the variable's value, or `null` when it is not set |
| `set_env_var(name: str, value: str)` | `void` — sets it for this process and the processes it starts afterwards |

A variable that is set to the empty string answers `""`, not `null`:

```kflat
import std.env.env_var

fun main(): int32 {
    val home = env_var("HOME") ?: return 1
    println("home is ${home}")
    val editor = env_var("EDITOR")?.as_str() ?: "vi"
    println("editor is ${editor}")
    return 0
}
```

The process's own command-line arguments are in core, with no import:
`arg_count()` and `arg_at(i)`, which borrows the argument rather than copying
it.

## std.io

Standard input, read a line or a number of bytes at a time. Both return
`null` once the input is exhausted:

```kflat
import std.io.*

fun main(): int32 {
    var lines = 0
    while true {
        val line = read_line() ?: break
        if line.byte_len() > 0 { lines = lines + 1 }
    }
    return lines
}
```

`read_bytes(n)` reads up to `n` bytes, and `at_end()` says whether the last
read reached the end of input.

`eprint` and `eprintln` are `print` and `println` for standard error, which is
where a program whose standard output carries a protocol writes its logs.

These read through the C library's buffer. A program that waits on standard
input alongside other streams reads it with a `Reader` over `Stream.stdin()`
instead (below), and not with both.

## std.process

Running a command:

```kflat
import std.process.*

fun main(): int32 {
    var cmd = Command.new("echo")
    cmd.arg("hello")
    cmd.arg("world")
    val result = cmd.status()
    return result.exit_code()
}
```

| Method | Returns |
|---|---|
| `Command.new(program: str)` | `Command` |
| `.arg(value: str)` | `void` — `mutating`, appends in place |
| `.current_dir(path: Path)` | `void` — `mutating` |
| `.env(key: str, value: str)` | `void` — `mutating`, sets it for the child |
| `.stdout_to(path: Path)` | `void` — `mutating`, truncates and redirects |
| `.status()` | `ExitStatus` |
| `.exec()` | `IoError` — only when the program could not be started |
| `.exit_code()` on `ExitStatus` | `int32` |
| `.success()` on `ExitStatus` | `bool` |

`Command` is **not** a builder. Every configuration method mutates in place
and returns `void`, so the receiver has to be a `var` and the calls have to be
separate statements. Chaining them — `Command.new("echo").arg("hello")` —
is rejected by `komp check`: `cannot call method `status` on `void``.

Arguments never pass through a shell, so no quoting or escaping is involved.
`status()` runs the command synchronously and blocks until the child exits.
`exec()` runs it in place of this process instead: the program keeps this
process's id, standard input, output and error, and nothing after a
successful call runs. It returns only when the program could not be started.

`spawn()` starts it instead, and answers a `Child` whose `stdin` and `stdout`
are pipes to this process; its standard error is this process's. A program
that cannot be run is an `Err` from `spawn()`, not an exit code later.

| On `Child` | Returns |
|---|---|
| `.stdin`, `.stdout` | `Stream` — write to one, read from the other |
| `.wait()` | `ExitStatus` — closes `stdin` first, then blocks until the child exits |
| `.try_wait()` | `ExitStatus?` — `null` while it runs |
| `.kill()` | `void` — `wait` then reports it, as exit code 128 |
| `.id()` | `int32` — the process id |

Dropping a `Child` that is still running kills it.

## std.stream, std.reader and std.poll

Talking to another program while it runs, from one thread. Three pieces, each
doing one thing:

- **`Stream`** is an open descriptor: a pipe end, or one of this process's
  standard streams. `read_available(max)` never blocks. It answers `Data`,
  `Pending` when the other end is open but quiet, `End`, or `Failed`.
  `write(text)` blocks until everything is taken, and writing to a pipe whose
  reader has gone is an `Err`, not a signal that ends the program.
- **`Reader`** buffers a stream into lines and counted runs of bytes. The
  `take_*` methods answer only from what is already buffered and never block.
  `fill()` pulls in whatever is waiting, and `read_line()` and
  `read_bytes(n)` wait for the rest.
- **`Poll`** waits on several streams at once, each added under a token you
  pick. `wait(timeout)` answers the tokens whose stream has input or has
  closed, or none when the timeout passed first. It reads nothing itself.

```kflat
import std.io.eprintln
import std.poll.Poll
import std.process.Command
import std.reader.Reader
import std.stream.Stream

fun main(): int32 {
    var child = Command.new("cat").spawn().unwrap()
    var from_child = Reader.new(child.stdout.take())
    var from_user = Reader.new(Stream.stdin())
    var poll = Poll.new()
    poll.add(from_user.stream(), 1)
    poll.add(from_child.stream(), 2)
    while !from_user.at_end() {
        val ready = poll.wait(Option.Some(Duration.from_millis(500))).unwrap()
        if ready.is_empty() {
            eprintln("still waiting")
            continue
        }
        val _user = from_user.fill()
        val _child = from_child.fill()
        while true {
            val line = from_user.take_line() ?: break
            val _sent = child.stdin.write("${line}\n")
        }
        while true {
            val line = from_child.take_line() ?: break
            println("cat said: ${line}")
        }
    }
    child.stdin = Stream.closed()
    while true {
        val line = from_child.read_line() ?: break
        println("cat said: ${line}")
    }
    return child.wait().exit_code()
}
```

```console
$ (printf 'one\ntwo\n'; sleep 1; printf 'three\n') | ./target/kflat/demo
cat said: one
cat said: two
still waiting
cat said: three
```

**Drain a reader before you wait on its stream.** A line that is already in a
`Reader`'s buffer does not make its stream ready, so a loop that waits
without taking it first can wait forever for input that has already arrived.

A struct's field cannot be moved out, so `take()` moves a stream out of the
`Child` or `Pipe` that holds it and leaves a closed one in its place.
Assigning `Stream.closed()` to a stream closes the one it replaces: that is
how a child learns that its input has ended. `pipe()` makes a connected
`reader` and `writer` inside the program.

This is single-threaded on purpose. `Poll` reports readiness and the caller
does the reading, which is the layer an async runtime is later built on, so
code written against it keeps working when one arrives.

## std.time

Reading the clock. The arithmetic — `Duration`, `Date`, `DateTime` — is
[`core`](core.md); this is the part that needs an operating system.

```kflat
import std.time.*

val t = now()               // current UTC DateTime
println(t)                  // "2026-08-21T11:54:56Z"
unix_seconds()              // seconds since the epoch

val started = Instant.now()
sleep(Duration.from_millis(50))
println(started.elapsed())  // "50ms"
```

**Two clocks, and they are not interchangeable.** `now()` reads the wall
clock: it names an instant everyone agrees on, and it can jump when the
machine is corrected. `Instant` reads the monotonic clock, which only ever
moves forward from an unspecified origin.

Use `Instant` for *how long*, and `now()` for *when*. Measuring a duration
against the wall clock is the classic bug — an NTP correction part-way
through yields a negative elapsed time. `Instant` therefore has no conversion
to a `DateTime`, and `elapsed()` cannot be negative.

`sleep` waits at least as long as asked, resuming if a signal interrupts it.
A non-positive duration returns immediately.

## What is missing

`std` is thin — the modules above are all of it. Not available ([#58]):

- Directory listing/walking
- Networking of any kind
- Threading or synchronization

The library surface grows as the language matures.

[#58]: https://github.com/komp-co/komp/issues/58
