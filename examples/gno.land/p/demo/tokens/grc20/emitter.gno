package grc20

// This file defines the opt-in hand-off that lets a registry realm own a
// token's identity and its event stream.
//
// # The problem
//
// Two Token objects created in one realm can share a Token.ID(), because the
// trailing id is caller-supplied and nothing outside the realm can tell the
// objects apart. Both then emit Mint/Burn/Transfer/Approval events carrying an
// identical "token" attribute and an identical pkg_path
// (gno.land/p/demo/tokens/grc20, since grc20 is what calls chain.Emit). A
// consumer reconstructing balances from events cannot attribute an event to the
// object that produced it.
//
// # Why it cannot be fixed inside grc20
//
// Distinguishing the objects requires an identifier no realm can reissue, which
// requires state that survives across transactions. A /p/ package holds no
// persistent state, so grc20 cannot own a counter. Any counter grc20 is *handed*
// is equally useless: state passed in as a struct or a pointer-to-struct can be
// copied by the caller — `snapshot := *gen` — and replayed to mint a second
// token carrying the first one's identifier. Handing out the counter is handing
// out the ability to defeat it.
//
// # The hand-off
//
// So the state must stay inside a realm that the creating realm cannot reach
// into. A Token may therefore be created against an Emitter — a registry realm
// — which does two things grc20 cannot do for itself:
//
//   - It issues the token's identifier from a counter held in its own package
//     state. Because that state is never returned to the caller, it cannot be
//     copied or replayed. IssueToken is a crossing method, so the registry reads
//     the creating realm from the live frame (cur.Previous()) instead of trusting
//     an argument.
//
//   - It emits the token's events from its own package. The VM stamps pkg_path
//     from the package that calls chain.Emit, so every event carries the
//     registry's path as an unforgeable label. A counterfeit Emitter cannot
//     borrow it: events emitted through a fake carry the fake's own path, so
//     consumers filter on pkg_path and are done.
//
// Together these close the gap. The registry never issues one identifier twice,
// so two Tokens cannot collide; and any Token that opted out is visible as such,
// because its events carry grc20's path rather than a registry's.
//
// # Note on capability
//
// Recording an event is a real capability: whoever holds a TokenEmitter can
// produce events bearing the registry's pkg_path. Token keeps its emitter in an
// unexported field and exposes no accessor, deliberately. Returning it through a
// narrowed interface would not help — a caller can assert the value back to a
// wider interface and recover the emitting methods, the same way an
// unexported-marker "seal" is bypassed by embedding (see IsCanonicalTeller). For
// the same reason a registry should verify provenance from its own records of
// what it issued, not by asking the token to describe its emitter.
//
// # What the registry's pkg_path attests, and what it does not
//
// The methods below are deliberately narrow. An earlier shape — a free-form
// Emit(kind string, attrs ...string) — let a holder choose the event type *and*
// its "token" attribute, so any realm could obtain a handle for its own
// namespace and then record a Transfer labelled with an id belonging to a
// different realm, carrying the registry's pkg_path. That defeats the whole
// point: the label is unforgeable, but what it labels was not.
//
// Typed methods close that. The implementation stamps the bound identifier
// itself, and the event type comes from this package's own vocabulary rather
// than from the caller, so the identifier on a registry-stamped event is always
// one the registry issued to the realm that is recording it.
//
// What remains, irreducibly, is that the issuing realm is trusted for the
// *contents* of its own tokens' events — a realm holding a handle can record a
// Transfer that no ledger performed, for an id in its own namespace. That grants
// it nothing new: it already owns the ledger behind that id and can mint or burn
// at will. So the guarantee is precisely:
//
//	a registry-stamped event is attributable to one identifier that this
//	registry issued exactly once, to the realm that owns it.
//
// It is not a claim that a ledger performed the operation. Attribution is the
// property consumers needed and could not get; ledger authenticity was never
// separable from trusting the issuing realm.
//
// # Where trust is anchored
//
// It follows that a consumer trusts a *set of registries*, chosen by pkg_path,
// and reads the streams they stamp. That is deliberate, and it is the only
// anchor available: the sole label the VM enforces is which package called
// chain.Emit, so any attribution scheme bottoms out in trusting some set of
// emitting packages. It is the same trust structure as a curated token list,
// improved in one respect — the label cannot be forged, so the decision is made
// once per registry rather than once per token.
//
// NewToken remains supported and unchanged. Tokens created through it have no
// emitter, emit under grc20's own pkg_path, and carry the ambiguity described
// above — which is what makes the guarantee legible to consumers rather than
// silent.

// Emitter is a registry realm that can issue token identities and record token
// events. Implementations live in /r/; grc20 imports none of them.
//
// IssueToken must be a crossing method so the implementation can authenticate
// the creating realm from cur.Previous() rather than from an argument. It must
// return a distinct identifier on every call, derived from state the caller
// cannot obtain — package-level state, never a returned struct.
type Emitter interface {
	IssueToken(cur realm, symbol string) TokenEmitter
}

// TokenEmitter is the per-token handle an Emitter returns. It is bound to one
// token identifier for its whole life, so copying it grants nothing its holder
// did not already have.
//
// The Emit* methods must call chain.Emit from the implementation's own package,
// so the VM stamps that package's path onto the event, and must write the bound
// identifier as the event's "token" attribute themselves — never a value taken
// from the caller. See the note on capability above for why the interface has no
// free-form emit method.
type TokenEmitter interface {
	// TokenID returns the identifier the Emitter assigned to this token.
	TokenID() string

	// EmitTransfer records a movement of amount between two addresses. An empty
	// from denotes a mint; an empty to denotes a burn.
	EmitTransfer(from, to address, amount int64)

	// EmitApproval records owner granting spender an allowance of amount.
	EmitApproval(owner, spender address, amount int64)
}
