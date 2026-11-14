# Demo — a task that cannot be finished, and the walk-back it produces

This task is designed to fail. Put it on the belt and watch what happens to it.

Nothing here needs a repo, a network, or anything on your machine: the three
steps below are arithmetic. Two of them are true. One of them is not, and no
seat, however confident, can make it true.

**What to watch for.** The belt does not read the seat's reply for a verdict.
Whatever the seat says it did, the runner re-runs every `verify:` command
itself and ticks only what exits 0. So on every leg:

- the two true steps tick,
- the third does not, and the checker's verdict on it is **appended to this
  file** under a `## Leg N — driver` heading,
- the task goes back to `queue/` to be tried again from what was actually
  wrong.

That repeats until the **leg ceiling** — the backstop that stops a task which
is technically still being worked but is going nowhere. Then the task moves to
`failed/` **whole**, with a `## Dead End` block naming the rule that fired and
the last verdict, and the loss is written to `logs/dead-ends.jsonl` and
`logs/notify.log`.

The file you end up with is the walk-back. It is not a summary written after
the fact; it is the record the legs wrote as they went, kept rather than
discarded. Read it top to bottom and you can see what was claimed, what was
proved, what could not be proved, and the exact point the belt decided to stop
instead of looping.

A seat that answers honestly gets there in one leg instead: ending a leg with
`RESULT: blocked` is a dead end immediately, with the seat's own reason in
place of the ceiling. Same walk-back, sooner. Both paths are worth seeing —
`examples/dead-end-demo.sh` runs the first one, with a stub seat that always
claims success, so it costs nothing and calls no model.

**The point is not that the belt failed.** Any runner can fail. The point is
that it stopped on purpose, said which rule stopped it, and left behind
everything it knew — instead of reporting success, or looping until someone
noticed the bill.

## Checklist
- [ ] two plus two is four :: verify: test $((2 + 2)) -eq 4
- [ ] the checker runs commands, not claims :: verify: echo proved :: expect: ^proved$
- [ ] two plus two is five :: verify: test $((2 + 2)) -eq 5
