---
name: terse-code-comments
description: >-
  The house rule for COMMENTS IN CODE, in every language: make the code say it, and where a comment
  is genuinely unavoidable, write it EXTREMELY short. Read this BEFORE writing or editing any code,
  and before adding any comment, KDoc, rustdoc, docstring, JSDoc, doc block, header comment, or
  inline note. Covers how to remove the need for a comment (naming, extraction, named constants),
  the short list of facts code cannot carry and a comment therefore may, the one-line ceiling, what
  to delete on sight, and what is OUT of scope (user-facing strings, commit messages, docs, specs,
  logs). Triggers: "add a comment", "document this", "explain this in the code", "write a docstring",
  "add KDoc", "comment this function", "clean up the comments", "why is this here".
---

# Terse code comments

The code is the explanation. A comment is either an admission that the code failed to explain
itself, or a fact the code cannot hold. Fix the first. Compress the second to almost nothing.

**The default is no comment.**

## First, remove the need

Before writing a comment, try to make it unnecessary:

- **The name is wrong** → rename. `// how many retries are left` over `n` means the variable is
  called `n`. Call it `retriesLeft` and delete the comment.
- **The block needs a heading** → extract it into a function whose name is that heading. A comment
  marking the start of a step is a function waiting to be named.
- **A number needs explaining** → make it a named constant. The name is the comment.
- **The expression is clever** → make it plain. Clever plus a comment is worse than obvious.
- **The comment says *what* the code does** → there is nothing to keep. Delete it.

A comment that survives this is one the code genuinely cannot carry.

## What a comment may carry

Only facts absent from the code itself:

- Units, scale, sign convention, element order, row- or column-major.
- Null and empty semantics where they differ in meaning — empty is not zeroed.
- Threading, locking, ownership, lifetime, allocation constraints on the caller.
- Why a constant has that value.
- A trap: something that looks wrong and is deliberate, or a known divergence from another system.
- A pointer to an external specification — the bare pointer with its section number, never a
  retelling of what it says.
- Why a value is withheld or a path fails closed.

Nothing else. Not the rationale, not the history, not the argument that led there.

## How short

One line. Three lines is the absolute ceiling and should be rare.

- A fragment, not a sentence. Drop the subject and the verb where meaning survives.
- One fact per comment.
- No emphasis, no bold, no headings inside a doc block, no second person, no "note that", no
  "this function", no hedging.

| Verbose | Terse |
|---|---|
| `// Increment the retry counter before the next attempt.` | *(deleted)* |
| `/** The largest cell, for scaling a heatmap. 0 when empty. */` | *(deleted — the body says it)* |
| `// We use 400 here because it is the conventional Clarke extent and the DTS grid's 600 crops to it without changing any classification.` | `// Clarke's conventional extent; cropping DTS's 600 changes no classification.` |
| `// counts is the 5x5 contingency table, truth-major, so cell (t, p) is truth bin t against forecast bin p at index t * BINS + p. Reading it transposed is well-formed and describes the opposite failure.` | `// Truth-major: cell (t, p) at t * BINS + p.` |
| `// This is null when the truth never crossed the threshold, which is an undefined ratio rather than a zero.` | `// Null where undefined, not zero.` |

## Delete on sight

- Any comment restating the line below it.
- `@param` / `@return` / `@throws` that repeat the signature.
- History: what it used to be, what it replaced, phase or version labels, ticket narration.
- Banners, dividers, `// --- section ---`, ASCII art, `//region`.
- Commented-out code. Version control holds it.
- Essays, worked arguments, rationale paragraphs, anything addressed to the reader.
- Comments on test functions that restate the test name.

## When editing existing code

- Removing a comment that restates the code needs no justification. Do it.
- Unsure whether the fact is derivable? Compress to one line rather than delete.
- Asked to clean comments? Change **only** comments — not a token of code, not a string literal, not
  an annotation, not formatting.
- Never lengthen a comment. Never add one that was not asked for.

## Scope

IN: comments and doc blocks in source of any language — `//`, `#`, `/* */`, KDoc, rustdoc,
docstrings, JSDoc, doc comments in build files.

OUT: user-facing strings (they have their own rule), commit messages, PR descriptions, `docs/`,
`README`, specifications, and log messages. Those are read by a person who is not looking at the
code.
