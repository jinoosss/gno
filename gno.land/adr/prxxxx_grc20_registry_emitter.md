# ADR: grc20 token identity and event attribution via a realm-bound Emitter

- Status: proposed
- Scope: `examples/gno.land/p/demo/tokens/grc20`, `examples/gno.land/r/demo/defi/grc20reg`
- Related: #6026 (duplicate token identifiers)

## Context

`grc20.NewToken` used to take the trailing segment of `Token.ID()` from its
caller as a `seqid.ID`. Two `Token` objects created in one realm could therefore
share an id, and both emitted `Mint`/`Burn`/`Transfer`/`Approval` events carrying
an identical `token` attribute and an identical `pkg_path`
(`gno.land/p/demo/tokens/grc20`, because grc20 is the package that calls
`chain.Emit`). A consumer rebuilding balances from the event stream could not
attribute an event to the object that produced it.

Two properties are needed and neither can be produced inside grc20:

1. **A non-reissuable identifier.** That requires state surviving across
   transactions. A `/p/` package holds none, so grc20 cannot own a counter. Any
   counter grc20 is *handed* is equally useless: a struct or pointer-to-struct
   can be copied by the caller (`snapshot := *gen`) and replayed.

2. **A label a consumer can filter on.** The only label the VM enforces is
   `pkg_path`, taken from the package whose frame calls `chain.Emit`
   (`m.MustPeekCallFrame(2).LastPackage.PkgPath`). grc20 emitting for everyone
   means every token shares one label.

Both are properties of *a realm*, so both have to come from one.

## Decision

Introduce `grc20.Emitter`: a **concrete struct**, bound to a realm at
construction, carrying that realm's *functions* rather than its state.

```go
type EventRecorder interface {
	RecordTokenEvent(id, kind string, attrs []string)
}

type Emitter struct {
	packagePath string        // bound under rlm.IsCurrent()
	nextID      func() string // the realm's counter, advanced per call
	recorder    EventRecorder // the realm's event sink, or nil
}

func NewEmitter(_ int, rlm realm, nextID func() string, recorder EventRecorder) *Emitter
```

`NewToken(name, symbol string, decimals int, em *Emitter, rlm realm)` draws the
id once, at construction, and stores `em.recorder` on the `Token`:

```
Token.ID() == rlm.PkgPath() + "." + symbol + "." + em.PackagePath() + ":" + em.NextID()
```

`grc20reg` supplies one:

```go
func Emitter(cur realm) *grc20.Emitter {
	return grc20.NewEmitter(0, cur, nextIDSeq, canonicalRecorder)
}
```

Four things follow, each from a specific mechanism.

- **Ids cannot be replayed.** The counter never leaves grc20reg; only
  `nextIDSeq`, which advances it, does. Copying an `Emitter` copies a reference
  to the same function, so `a, b := *em, *em` yields two handles driving one
  counter.

- **`packagePath` cannot be forged.** `NewEmitter` asserts `rlm.IsCurrent()`, so
  only code executing inside grc20reg can produce an `Emitter` claiming
  grc20reg's path. `Register` accepts only `token.EmitterPath() == cur.PkgPath()`.

- **The `pkg_path` label cannot be borrowed.** `recorder.RecordTokenEvent` is
  declared in grc20reg, so the VM stamps grc20reg's path. A realm emitting for
  itself gets its own path (or grc20's, for an `Emitter` with `recorder == nil`),
  and `Token.EventPath()` reports which without reading an event.

- **The handle is inert in the caller's hands.** `recorder` is an unexported
  field with no exported method reaching it. `Token.emit` is the only path to it
  and is itself unexported. A realm may keep the very `*Emitter` it passed to
  `NewToken` — see `r/demo/defi/grc20reg/filetests/emitter_capture_filetest.gno`,
  which does exactly that — and still cannot record a single event.

That last point is the reason this is a struct and not an interface pair. An
earlier iteration passed a `grc20.Emitter` interface *implemented by the creating
realm*, whose `IssueToken` returned a `grc20.TokenEmitter`. grc20 called it, so
the creating realm saw the handle first and could keep it:

```go
type capturing struct{ captured grc20.TokenEmitter }

func (w *capturing) IssueToken(cur realm, symbol string) grc20.TokenEmitter {
	h := grc20reg.Emitter().IssueToken(cross(cur), symbol)
	w.captured = h // the real handle
	return h
}
```

`w.captured` could then record a `Transfer` for a live token, under the
registry's `pkg_path`, with no ledger movement behind it. Narrowing the handle's
methods does not close that — the hole is that the caller holds it at all.

## Alternatives considered

**Keep the interface pair, narrow `TokenEmitter` to typed methods.** Replaces a
free-form `Emit(kind string, attrs ...string)` with `EmitTransfer`/`EmitApproval`
that stamp the bound id themselves. This stops a holder labelling an event with
*someone else's* identifier, but a captured handle can still record transfers its
own ledger never performed. Rejected: it narrows the forgery instead of removing
the capability.

**Have grc20reg construct the `Token` itself**, so no handle ever crosses into
caller code. Closes the same hole, but moves token construction into the registry
and makes the registry a required dependency of every token realm — a realm that
wants distinct ids without registering has nowhere to go. Rejected as too large a
coupling for the property being bought.

**Store the recorder as a `func` field on the `Token`** rather than an interface.
Equivalent in reachability; an object reference was preferred because it is the
persistence shape already exercised across transactions (verified by
`grc20_registry_emit.txtar`, where foo20's token is built at genesis and emits
under grc20reg's path in a later transaction).

**Have the registry check every event against an `issued` tree.** Rejected as
redundant: the id reaching `RecordTokenEvent` is the one grc20 bound at
construction from this registry's own `nextIDSeq`, and no package outside grc20
can reach the recorder. The property holds by construction, and an AVL lookup on
`Transfer` is on the hot path.

## Consequences

- `grc20.NewToken`'s signature changes from `(…, id seqid.ID, rlm realm)` to
  `(…, em *Emitter, rlm realm)`. Every caller in `examples/` is updated;
  registrable realms take `grc20reg.Emitter(cross(cur))`, others build their own.
- `Token.ID()` grows the issuing realm's path:
  `gno.land/r/demo/defi/foo20.FOO.gno.land/r/demo/defi/grc20reg:0000001`. The
  registry key stays `rlmPath.symbol`, so lookups are unaffected.
- Events of registered tokens now carry `pkg_path`
  `gno.land/r/demo/defi/grc20reg` instead of `gno.land/p/demo/tokens/grc20`.
  Indexers filtering on grc20's path must add the registry's.
- The `register` event gains an `emitter` attribute, and `Render` reports the
  path a consumer should filter on.
- What is *not* claimed: a stamped event is attributable to one identifier the
  registry issued exactly once, to the realm named in it. It is not evidence that
  a ledger performed the operation — the token realm owns its ledger and can mint
  or burn at will. Ledger authenticity was never separable from trusting the realm
  that owns the ledger; attribution is the property consumers needed and could not
  get.
