---
name: plain-language
description: >-
  Write an explanation the reader can follow without knowing the codebase. Use whenever you are
  EXPLAINING rather than doing: summarising what a change does, reporting what an investigation or
  review found, describing why something broke, laying out options, answering "what does this mean"
  or "explain this", or writing the closing summary of a long piece of work. Also use when the reader
  asks for it directly — "in plain language", "simply", "no jargon", "like I'm not the one who wrote
  this", "what does that actually mean". Covers what counts as jargon, the order to put things in,
  how to keep facts intact while shedding vocabulary, and when a technical term is the right word.
  Does NOT apply to code, comments, KDoc, commit messages, specifications, or logs.
---

# Plain language

The reader is capable. They are not inside your context. Everything you spent the last hour learning
is invisible to them, and every term you picked up along the way is a small toll you are charging
them to understand their own project.

Write so the toll is zero.

## Put the answer first

Lead with the conclusion, in one sentence, before any of the reasoning that produced it. The reader
decides how much of the rest they need. Burying the verdict under the method is the single most
common way an explanation fails.

> Wearing two sensors at once works. Switching which one the app trusts does not.

Then the detail, for whoever wants it.

## What counts as jargon

Not just acronyms. Any word that is doing work the reader cannot see:

- **Names from the code.** A class, a function, a table, a flag. `viewingNonAuthoritative` means
  nothing outside the file it lives in. Say what it *is*: "whether the panel is showing a sensor the
  app isn't trusting".
- **Names from the trade.** Idempotent, chokepoint, invariant, projection, hydrate, race, contract,
  seam. Each has a plain equivalent. "Runs twice safely", "the one place it can go wrong", "a rule
  that must always hold", "a copy kept up to date", "load at startup", "two things happening at once",
  "the agreed format", "the joint between two parts".
- **Names you just invented.** If a phrase appeared for the first time in your own last message,
  the reader has no idea what it means. Define it or drop it.

## Keep every fact. Shrink only the words

This is the line not to cross. A plain sentence that has lost a number, a name, a limit, or the
reason is not plainer — it is worse. Shortening is not the goal; being followable is.

| Loses the fact | Plain, and complete |
|---|---|
| "There were some sync issues." | "After you switch sensors, the next full sync can write a second copy of your whole history." |
| "A performance regression." | "It was writing to the database about 2,900 times a day for no new information." |
| "The migration is unguarded." | "Nothing tests the database upgrade, so a broken one would ship unnoticed." |

## Explain the consequence, not the mechanism

The reader wants to know what happens to them. Reach for the mechanism only when it is the thing
being asked about, or when the consequence makes no sense without it.

> Not: "`onRawAdvert` gates on the active set, and the migration seeds `active` from the single
> pre-v14 authoritative flag."
>
> But: "Someone already wearing two sensors would have had the second one quietly stop being
> recorded the moment they installed this version."

## Own mistakes in the plainest words of all

If you broke something, say so in a short sentence, early, with no cushioning. Then say what it
would have cost and what you did about it. No passive voice hiding who did it, no burying it in the
middle of a list, no softening it into "an issue was introduced".

> "One bug was mine. I already fixed it."

## When a technical term is the right word

Use it when it is genuinely the most exact word AND the reader already owns it — their own domain,
their own tools, a term they used first. A diabetes app's user knows what a sensor and a reading
are; do not translate those into something vaguer. Precision beats simplicity when the two conflict.
The test is whether the term is *theirs*, not whether it is standard.

## Shape

- Short sentences. One idea each.
- Concrete nouns. "The app", "your history", "the second sensor" — not "the subsystem", "the data
  layer", "the secondary source".
- Group related things under a plain heading rather than making one long list.
- A table only when you are genuinely comparing things side by side.
- No preamble, no "in essence", no closing summary of the summary.

## Where this does not apply

Code, comments, KDoc, commit messages, specifications, PR descriptions, logs, and anything written
for a machine or for a reader who is explicitly inside the code. Those have their own registers and
their own precision requirements. This is for prose addressed to a person.
