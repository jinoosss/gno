# PR 6043: grc20reg constructs the token instead of exporting its Emitter

## Context

PR 6043 lets `grc20reg` own a token's identity and event stream. A token realm
opted in at construction:

```go
Token, ledger := grc20.NewTokenWithEmitter("Foo", "FOO", 4, grc20reg.Emitter(), cur)
```

`tokenEmitter.Emit` calls `chain.Emit` from `grc20reg`, so the VM stamps
`pkg_path = gno.land/r/demo/defi/grc20reg` on every event. The claim was that
consumers filter on that stamp and "need trust nothing in-band".

Review comment `r3734864480` disputed it. Two problems, both from `Emitter()`
handing out a route to a `TokenEmitter`.

**A handle can name another realm's token.** `grc20reg.Emitter().IssueToken(...)`
is callable by anyone, and `Emit(kind string, attrs ...string)` passed both
arguments to `chain.Emit` verbatim. Any realm could emit, under `grc20reg`'s
pkg_path, a `Transfer` naming another realm's token id. Verified on a live node:
byte-identical to a genuine event.

**A handle can name a ledger that never moved.** `NewTokenWithEmitter` calls
`IssueToken` on an `Emitter` the *caller* supplies, so the handle bound for
`Token.emitter` passes through the caller's own code:

```go
func (w *capturing) IssueToken(cur realm, symbol string) grc20.TokenEmitter {
	h := grc20reg.Emitter().IssueToken(cross(cur), symbol)
	w.captured = h // kept on the way through
	return h
}
```

`Token.emitter` being unexported does not help — the value is intercepted before
it gets there. Verified across three transactions on a live node: the captured
handle persists in realm state indefinitely and emits `Transfer` for a
registered token while `TotalSupply()` stays 0.

## Decision

Both need a handle to exist outside `grc20`. Rather than harden `Emit`, stop the
handle from getting out: replace `Emitter()` with a constructor that supplies
the emitter itself.

```go
func NewToken(_ int, rlm realm, name, symbol string, decimals int) (*grc20.Token, *grc20.PrivateLedger) {
	return grc20.NewTokenWithEmitter(name, symbol, decimals, canonicalEmitter, rlm)
}
```

`grc20` returns the `TokenEmitter` into *this* function rather than into the
caller's, so nothing outside `grc20` ever holds one. `IssueToken` is now
reachable only on a value nothing hands out.

The signature follows the `Teller` convention (`Transfer(_ int, rlm realm, ...)`):
the leading `int` keeps `rlm` early while stopping the compiler from reading this
as a crossing function. Non-crossing is load-bearing — the frame stays the
caller's, so `Token.ID()` keeps the creator's namespace, `issued` records the
creator, and `Register` is unchanged. Make it crossing and the frame becomes the
registry's, which forces `Token.ID()` and the lookup key apart.

`grc20.NewTokenWithEmitter` stays exported. A realm may still pass its own
`Emitter`, but events emitted through it carry that realm's pkg_path, not the
registry's.

## Alternatives considered

- **Bind the event to its handle's id: have `Emit` write `token` from `t.id` and
  panic on a caller-supplied one that disagrees.** Closes the first problem, not
  the second, and once `Emitter()` is gone its guard cannot fire — while costing
  **55,630 gas on every token event**, measured. Dropped in favour of removing
  the route.

- **Gate `Emit` on the caller.** Impossible: `grc20` is a pure package and
  creates no realm frame, so `cur.Previous()` is the token's realm whether the
  call came through `grc20` or directly.

- **A capability argument only `grc20` can construct.** Defeated by the same
  wrapper — it sits in the call path and captures the value on the first
  legitimate emit.

- **Return only the id; emit via `EmitFor(cur, id, ...)`.** The check would be
  `IssuedTo(id) == cur.Previous()`, which the token's realm passes by definition
  and can therefore call directly.

- **Registry-owned identity: make `NewToken` a crossing function that also
  registers.** Also closes both, but moves `Token.ID()` into the registry's
  namespace, which forces the lookup key and the id apart and rewrites
  `Register`'s provenance check. Much larger diff for no additional guarantee.

## Consequences

**Storage attribution moves to the registry.** Measured on a live node, one
token and 50 holders:

| | grc20reg | creating realm |
|---|---:|---:|
| Setup, before | 3,925 | 3,018 |
| Setup, after | 6,798 | 140 |
| Mint x50, before | 0 | 100,840 |
| Mint x50, after | 101,433 | 0 |

Totals are unchanged (~6.9KB and ~101KB); what changes is who holds the deposit.
Objects are allocated while executing `grc20reg`'s code, so the registry owns the
token and its balance tree, and its storage grows with every token's holder set.

This is the price of the fix and it is not avoidable within this design: either
the caller supplies the emitter — and can capture it — or the registry constructs
and owns the result. Worth a deliberate decision before merge.

**No API breakage.** `Emitter()` was added by this PR and never shipped. Every
caller was an in-package test; those now use `NewToken` or `canonicalEmitter`.

## Tests

- `filetests/emitter_counterfeit_filetest.gno` — one realm, two tokens: the
  registry-built one emits under `grc20reg`'s pkg_path, the one built with a
  counterfeit `Emitter` under its own.
- `filetests/emitter_pkgpath_filetest.gno` — updated to the new constructor.
- `emitter_test.gno` — updated; the copy-the-emitter replay test still exercises
  `grc20.NewTokenWithEmitter` directly.
