# Writing the KFlat book

The book is the user-facing half of the documentation: someone who wants to
*use* KFlat, not work on komp. Contributor documentation lives one level up in
`docs/`.

## The one rule

**Every example is compiled and run before it is written down.**

Not "looks right". Not "matches the spec". Compiled, with the komp binary built
from the tree you are working in, and — where it produces a value — run, with
the exit code checked.

This is not a quality bar for its own sake. A language book written from
intention rather than observation is how a project ends up documenting a
language it does not have. Everything in here should be reproducible by a
reader typing it in.

## When an example does not work

That is a finding, not an obstacle. In order:

1. **Reduce it.** Cut it to the smallest program that still fails.
2. **Check whether it is known.** Search open issues before filing.
3. **File it** if it is new, with the reduced program and the exact output.
4. **Then decide what the chapter says.** Either write the example a way that
   works, or document the limitation with a link to the issue. Never quietly
   route around a defect and leave the reader to rediscover it.

A limitation of the language or compiler goes to kf-lang's `limitations.md`; one
of komp's stays in the chapter that hits it, with its issue.

## What good looks like

- **Show the smallest thing that makes the point.** A chapter on `when` does
  not need a bank account simulation.
- **Say why, not just how.** "Operators dispatch through core traits" is worth
  more than a table of operators, because it tells the reader what to do when
  they want `+` on their own type.
- **State costs.** This is a systems language. If something allocates, copies,
  or monomorphizes into N copies, say so.
- **Be honest about maturity.** A reader who hits an unimplemented thing you
  did not warn them about trusts nothing else you wrote.
- **No marketing.** No "blazingly fast", no "simply", no "just". If a thing is
  simple, the example demonstrates it without the adverb.

## Conventions

- One `#` title per file, matching its `SUMMARY.md` entry.
- Code blocks are tagged ```` ```kflat ```` for KFlat and ```` ```console ````
  for terminal output.
- Show real diagnostics, copied from the compiler, not paraphrased.
- Link chapters with relative paths so the sources stay readable in-tree.
- British or American spelling — just be consistent with what is already there.
- File size: keep a chapter under ~300 lines. Split rather than sprawl.

## Ground truth

`tests/cases/*.kf` are directive-driven fixtures that are run by CI. Each one
is a small program with a known outcome, so they are the most reliable
statement of what the language does today. Several chapter stubs name the
fixtures relevant to them. Read those before writing, and prefer adapting one
over inventing an example that has never been run.

`libs/core`, `libs/alloc` and `libs/std` are the library surface. They are
small enough to read in full, and doing so is faster than guessing.

## Layout

The sources are laid out for mdBook (`book.toml`, `src/SUMMARY.md`) so that
`mdbook serve docs/book` works if anyone wants HTML. Nothing in the build
depends on it and the tool is not installed — the sources are meant to be read
in-tree, and the layout is just a free option.
