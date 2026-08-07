# GRC20 token ids: an issuer that holds a closure, not a counter

## Context

Issue #6026: a realm can mint two GRC20 tokens reporting the same `Token.ID()`.
Their `Transfer` and `Approval` events are then byte-identical in every field a
consumer can observe, so an indexer or a downstream realm cannot tell a
registered token's transfers from a shadow token's.

An earlier attempt added `p/onbloc/identifier.Generator` — a struct holding a
package path and a per-block counter — and had `grc20reg` expose its instance
through `IdentifierGenerator() *identifier.Generator`. `Register` then trusted
any token whose `IdentifierPath()` matched the registry's path.

That check does not hold. Handing out a pointer to a struct hands out the
struct: dereferencing it into a copy is legal from any package regardless of
field visibility, and the copy carries the registry's package path *and its
counter value*. Two lines reproduce #6026 unchanged:

```go
g := grc20reg.IdentifierGenerator()
a, b := *g, *g
canonical, _ := grc20.NewToken("Canonical", "DUP", 6, &a, cur)
shadow, _ := grc20.NewToken("Shadow", "DUP", 6, &b, cur)
// canonical.ID() == shadow.ID(), and both pass the trusted-issuer check
```

Nor was it a same-transaction artifact: that generator reset its counter on each
height change, so one captured copy stayed in lockstep with the registry in
every later block.

Two properties of that design were load-bearing and both were illusory. The
`sha256`+`cford32` digest added nothing to unforgeability — its inputs (package
path, height, counter) are public and the sequence is fully deterministic —
while costing readable ids and adding a 64-bit birthday bound a counter did not
have. And the "trusted issuer" comparison was a string equality on state the
caller could copy.

## Decision

Keep the issuer and the API shape callers already know. Change what it
*holds*: the counter stays in the creating realm, and the issuer carries a
function over it.

```go
// p/demo/tokens/grc20
type IDIssuer struct {
	packagePath string        // owning realm, captured at construction
	nextID      func() string // the owning realm's counter, advanced per call
}

func NewIDIssuer(_ int, rlm realm, nextID func() string) *IDIssuer
func (i *IDIssuer) PackagePath() string
func (i *IDIssuer) NextID() string
```

`rlm.IsCurrent()` binds `packagePath` from the creating realm's live crossing
frame, so no realm can create an issuer attributed to another. `NewToken`
calls `NextID` once and records the path as the token's `IdentifierPath()`;
`Register` accepts only tokens whose identifier path is the registry itself.

The registry keeps its counter private and its accessor becomes crossing:

```go
var idSeq seqid.ID

func IdentifierIssuer(cur realm) *grc20.IDIssuer {
	return grc20.NewIDIssuer(0, cur, nextIDSeq)
}

func nextIDSeq() string { return idSeq.Next().String() }
```

Copying an issuer now copies nothing that matters. Under the declaring-realm
borrow rule `nextIDSeq` runs with grc20reg's authority against grc20reg's counter
no matter who holds the issuer calling it, so every copy drives the *same*
counter forward. The reproduction above yields `…DUP.0000001` and `…DUP.0000002`,
and a captured copy falls further behind the live sequence each block rather
than tracking it.

Two changes ride along, both required for coherence:

- The digest is gone. Codes are the counter rendered directly, so ids read as
  `gno.land/r/demo/defi/foo20.FOO.0000001`.
- The registry key returns to `fqname(rlmPath, symbol)`. The earlier attempt
  keyed by `fqname(rlmPath, slug)`, which collapsed to the bare realm path for
  single-token realms — a live-chain state migration that also removed lookup by
  `(realm, symbol)`, the affordance grc20reg exists to provide.

`identifier` moves into `p/demo/tokens/grc20` as `idgenerator.gno` rather than
staying a separate package. Its correctness argument is inseparable from how
`NewToken` uses it, and self-contained-per-standard is the established
convention: `p/demo/tokens/grc721` carries its own copies of `validName`,
`validSymbol`, `isAlnum`, `MaxNameLen` and `MaxSymbolLen`. grc721 will want this
mechanism — it builds `ID()` as `origRealm + "." + symbol` with no code segment
at all, so it has the #6026 collision in a starker form — but the trigger for
extracting a shared `/p/` issuer is the second user, not the first.

## Alternatives considered

**Patch the issuer in place.** More private fields, validation inside
`NextID`, more string comparisons. A copy bypasses `NextID` entirely by taking
the fields wholesale; as long as the counter is reachable from the realm holding
the issuer it can be copied and replayed.

**A crossing accessor returning a string** (`NextTokenID(cross(cur)) string`).
Removes the copyable state, but one returned string can be passed to two
`NewToken` calls. Calling `NextID` inside `NewToken` is what makes issuance and
construction atomic.

**Let the registry construct the token** (`grc20reg.NewToken(cross(cur), ...)`).
Atomic by construction, but `Token` and `PrivateLedger` would be allocated in the
registry's storage context, moving storage cost and ownership of every token's
ledger to grc20reg.

**Single-use tickets with a spend guard.** An intermediate revision had the
registry hand out a ticket carrying a fixed code plus a guard closure recording
it as spent in an `avl.Tree`; a copied ticket found the code taken and aborted.
It works, but needs a tree, a write per issuance, and a new concept for callers.
Deriving the code from the closure at call time removes all of it — there is no
code to double-spend, because a copy that calls `NextID` just gets the next one.

**Trust the counter's monotonicity alone, with no closure indirection.**
`seqid.ID.Next()` never repeats — but that is a statement about a *single*
counter. The failure mode is a *forked* counter. Verified side by side: a
issuer holding the counter in a field lets two copies mint tokens with
identical ids; one holding the creating realm's closure does not.

**Drop ids and let the registry reject duplicates.** Migration-free, but leaves
#6026 open: a shadow token never needs to be registered to emit events a consumer
cannot distinguish from the registered token's.

## Consequences

- `grc20reg.IdentifierGenerator()` becomes `grc20reg.IdentifierIssuer(cross(cur))`:
  renamed for what it now returns, and crossing so the issuer is bound to a live
  frame rather than read out of realm state.
- `Token.IdentifierPath()` keeps its name and meaning. `p/onbloc/identifier` is
  removed; the core token standard no longer depends on a personal namespace.
- A realm that will not register its token can create its own issuer instead
  of depending on `r/demo/defi/grc20reg`. Such a token records itself as its
  identifier path and is not registrable — the two usage patterns are now
  distinguishable rather than contradictory. The earlier attempt shipped docs and
  a filetest recommending a realm-local issuer while `Register` demanded the
  registry's, making every token built as documented permanently unregistrable.
- Holding an issuer grants no more than calling `IdentifierIssuer` again
  would, so one may be stored or passed on freely.
- `nextID` must advance state the creating realm owns. This is documented, not
  enforced — no mechanism can enforce it, since `/p/` packages have no storage
  and a closure's captured state cannot be introspected. It is contained rather
  than prevented: a degenerate `nextID` produces tokens whose `IdentifierPath()`
  is the offending realm itself, which `Register` rejects, so the damage is
  confined to that realm's own unregistered tokens.
- `&grc20.IDIssuer{}` is constructible from any package (the type is exported,
  its fields are not), so `NewToken` checks the `nextID` field rather than only
  the pointer; otherwise it would die on a nil call inside `NextID`.
- Registry keys are unchanged from master (`wugnot` stays
  `gno.land/r/gnoland/wugnot.wugnot`) — no state migration. The register event
  keeps its `token_path` field and gains `token_id`.
- `Token.ID()` values do change: the trailing code now comes from the registry's
  global counter rather than a per-realm one, so `foo20.FOO.0000000` becomes
  `foo20.FOO.0000001`.
