# ADR: bind `grc20.TokenEmitter` to the identifier the registry issued

Follow-up to #6043 (`feat(grc20): let a registry own token identity and event
emission`), which this ADR assumes as context.

## Context

#6043 makes a token's event stream attributable by moving `chain.Emit` into a
registry realm. The VM stamps `pkg_path` from the package that calls
`chain.Emit`, so a token that opted in has every event labelled with the
registry's path, and nothing running in a realm can forge that label. The PR
states the consequence as: *consumers filter on `pkg_path` and need trust
nothing in-band.*

Three questions were raised in review. Two are about intent; one turned out to
be a defect.

### The defect: the label was unforgeable, what it labelled was not

`Emitter()` and `IssueToken` are public, and `TokenEmitter` carried a free-form
`Emit(kind string, attrs ...string)` that passed its arguments straight to
`chain.Emit`. Any realm could therefore take a handle for its own namespace
without going through `grc20.NewTokenWithEmitter`, and record an event whose
`token` attribute names a **different realm's** token — carrying the registry's
`pkg_path`. Reproduced against #6043's branch:

```
"type": "Transfer"
"token": "gno.land/r/demo/victim.VIC.1"      <- chosen by the caller
"from": "g1victim"  "to": "g1attacker"  "value": "1000000"
"pkg_path": "gno.land/r/demo/defi/grc20reg"  <- stamped by the VM
```

`IssueToken` binds the issued identifier to the calling realm's namespace;
`Emit` did not carry that binding forward. So a consumer filtering on
`pkg_path` still had to trust the in-band `token` attribute, which is the
property the PR set out to remove.

### The two questions of intent

- Registration stays open to tokens built with plain `NewToken`, whose events
  are ambiguous. Should `Register` reject them instead?
- The trustworthy label is a registry's `pkg_path`, so a consumer must anchor
  trust in a set of registries it chooses to trust.

## Decision

### 1. Replace free-form `Emit` with typed methods

```gno
type TokenEmitter interface {
	TokenID() string
	EmitTransfer(from, to address, amount int64)
	EmitApproval(owner, spender address, amount int64)
}
```

The implementation writes the `token` attribute from the identifier bound to
the handle, never from an argument, and the event type comes from grc20's own
vocabulary rather than the caller's. A handle can then only speak for the
identifier it was issued. Event payloads are byte-identical to #6043's, so
`emitter_pkgpath_filetest.gno`'s golden output is unchanged.

`grc20.Token` gains `emitTransfer`/`emitApproval` in place of the single
`emit`, each routing through the emitter when there is one and calling
`chain.Emit` with the same attributes otherwise.

**What the registry stamp now attests**, stated explicitly in `emitter.gno`:

> a registry-stamped event is attributable to one identifier that this registry
> issued exactly once, to the realm that owns it.

It is *not* a claim that a ledger performed the operation. A realm holding a
handle can still record a `Transfer` no ledger performed, for an identifier in
its own namespace — but it already owns the ledger behind that identifier and
can mint or burn at will, so this grants it nothing new. Ledger authenticity
was never separable from trusting the issuing realm; attribution is the
property consumers could not previously get, and it now holds.

### 2. Keep `Register` open; make the opt-out queryable

`Register` continues to accept tokens built with `NewToken`. Rejecting them
would break every already-deployed token and disable the registry's primary job
— discovery — in service of a guarantee that holds per *event*, not per
registration. It would also push those tokens into private registries, which
enlarges the trust-anchor problem below rather than shrinking it.

What #6043 lacked was a way to learn a token's status *after* the fact: the
`emitter` attribute exists only on the `register` event, so a consumer that
started indexing later could not recover it. Added:

```gno
func EmitterPath(key string) (string, bool)
```

It attests only for tokens the registry issued, returning this realm's path;
everything else is `("", false)`. That mirrors the `emitter` attribute's
meaning exactly, and it is deliberately not a three-way answer: a token built
with `NewToken`, a token routed through a *different* registry, and an
unregistered key are indistinguishable from here. Separating them would mean
asking the token to describe its emitter — the one thing this design refuses to
trust. It answers from the registry's own `issued` records, the same discipline
`Register` already followed. `Render`'s per-token page shows the same verdict.

A getter on `grc20.Token` was considered and rejected: grc20 cannot determine
an emitter's package path except by asking the emitter, and a counterfeit
emitter would simply name the real registry while emitting under its own path.
Self-reported provenance is exactly what #6043 avoids.

### 3. Make `IssuedTo` sound by construction

`IssuedTo` is keyed by identifier *string*, and the two identifier shapes could
in principle meet: a registry identifier ends in a decimal sequence number,
while a `NewToken` identifier ends in `seqid.ID.String()`, which is always
exactly 7 or 13 characters — and every 7-character decimal is a reachable
`seqid` encoding (`seqid.ID(1<<30).String() == "1000000"`). A realm that had
taken 10^6 identifiers from the registry for one symbol could then build a
`NewToken` colliding with one of them and read as registry-issued.

Unreachable in practice, but the point of these records is that they hold by
construction. `nextSequence` now steps over the 7- and 13-digit bands. The
sequence enters each band exactly at its lower bound, so multiplying past it
suffices.

### 4. The trust anchor is a registry set — confirmed as intended

Yes, and it is not avoidable at this layer. The only label the VM enforces is
"which package called `chain.Emit`", so any attribution scheme bottoms out in
trusting some set of emitting packages. This is the same trust structure as a
curated token list, with the improvement that the label itself cannot be
forged, so the trust decision is made once per registry rather than once per
token. Recorded in `emitter.gno` rather than changed in code.

## Consequences

- `grc20.TokenEmitter` changes shape. Nothing outside grc20/grc20reg
  implements it (verified by search) and #6043 is unmerged, so there is no
  deployed implementer to migrate.
- Adding a grc20 event type requires an interface change rather than a new
  `kind` string. Deliberate: free-form kinds are what let a holder speak
  outside its binding. grc20's event set (`Transfer`, `Approval`) is fixed by
  the standard.
- `grc20reg` hardcodes its own path as `selfPkgPath` (there is no
  `CurrentRealm()` in `chain/runtime`, and `chain/runtime/unsafe` is not worth
  importing for a getter). `TestSelfPkgPathMatchesTheRealm` pins it to
  `cur.PkgPath()`.
- Registry-issued sequence numbers skip two decimal widths, so they are not
  contiguous. Only `nextSequence` depends on that.

## Alternatives considered

- **Keep `Emit`, validate inside the implementation** — whitelist `kind` and
  overwrite a caller-supplied `token` key. Smaller diff, but the guarantee
  would live in one implementation's discipline rather than in the interface
  every implementation must satisfy.
- **Restrict `Register` to emitter-issued tokens** — see §2.
- **Bind the handle to the `*Token` object** instead of to the identifier
  string, so `Register` could compare pointer identity. Structurally the
  strongest form, but it requires the registry to store a pointer for every
  identifier it ever issues, including tokens never registered, and §3 closes
  the same gap without the storage.
