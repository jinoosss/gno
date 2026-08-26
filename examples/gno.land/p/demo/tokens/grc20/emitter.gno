package grc20

// This file defines the hand-off that lets a registry realm own a token's
// identity and its event stream.
//
// # The problem
//
// Two Token objects created in one realm could share a Token.ID(), because the
// trailing id was caller-supplied and nothing outside the realm could tell the
// objects apart. Both then emitted Mint/Burn/Transfer/Approval events carrying
// an identical "token" attribute and an identical pkg_path
// (gno.land/p/demo/tokens/grc20, since grc20 is what calls chain.Emit). A
// consumer reconstructing balances from events could not attribute an event to
// the object that produced it.
//
// # Why it cannot be fixed inside grc20
//
// Distinguishing the objects requires an identifier no realm can reissue, which
// requires state that survives across transactions. A /p/ package holds no
// persistent state, so grc20 cannot own a counter. Any counter grc20 is *handed*
// is equally useless: state passed in as a struct or a pointer-to-struct can be
// copied by the caller — `snapshot := *em` — and replayed to mint a second token
// carrying the first one's identifier. Handing out the counter is handing out
// the ability to defeat it.
//
// # The hand-off
//
// So the state stays inside a realm the creating realm cannot reach into, and
// what crosses the boundary is an Emitter: a realm-bound handle carrying that
// realm's own functions rather than its state. It does two things grc20 cannot
// do for itself.
//
//   - It draws the token's identifier from a counter held in the issuing realm's
//     package state. Because the counter is never returned, only advanced, a
//     copy of an Emitter cannot replay it: every copy drives the same counter,
//     so no two calls yield the same id.
//
//   - It records the token's events from the issuing realm's own package. The VM
//     stamps pkg_path from the package that calls chain.Emit, so every event
//     carries the issuing realm's path as an unforgeable label. A counterfeit
//     Emitter cannot borrow it: events recorded through one carry the
//     counterfeit's own path.
//
// # Why the handle is inert
//
// Recording an event is a real capability: whoever can reach a registry's
// recorder can produce events bearing that registry's pkg_path. An earlier shape
// of this hand-off passed the recorder through an interface the creating realm
// implemented, so the creating realm saw — and could keep — the very handle
// grc20 was about to bind:
//
//	type capturing struct{ captured grc20.TokenEmitter }
//
//	func (w *capturing) IssueToken(cur realm, symbol string) grc20.TokenEmitter {
//		h := grc20reg.Emitter().IssueToken(cross(cur), symbol)
//		w.captured = h // the real handle, kept
//		return h
//	}
//
// Afterwards w.captured could record a Transfer for a live token that no ledger
// had performed, under the registry's own path. Narrowing what the handle can
// say does not close that: the hole is that the caller holds it at all.
//
// Emitter closes it by being a concrete struct rather than an interface, with
// the recorder in an unexported field and no exported method that reaches it.
// The creating realm may hold an Emitter for as long as it likes — it is welcome
// to, and NewToken takes one that way — and still cannot record anything,
// because reaching `recorder` from outside grc20 does not compile. The only path
// to it is Token.emit, and a Token only ever emits what its own ledger just did.
//
// # What the issuing realm's pkg_path attests, and what it does not
//
// The identifier on a stamped event is written by the recorder from the id grc20
// bound to the token at construction, which came from that same realm's counter
// one call earlier. So a stamped event is attributable to one identifier the
// issuing realm handed out exactly once, to the realm named in that identifier.
//
// What remains, irreducibly, is that the token realm is trusted for the
// *contents* of its own tokens' events: it owns the ledger and can mint or burn
// at will, so an event it causes is authentic by definition and an accounting it
// dislikes is one it can simply not perform. Attribution is the property
// consumers needed and could not get; ledger authenticity was never separable
// from trusting the realm that owns the ledger.
//
// # Where trust is anchored
//
// It follows that a consumer trusts a *set of issuing realms*, chosen by
// pkg_path, and reads the streams they stamp. That is deliberate, and it is the
// only anchor available: the sole label the VM enforces is which package called
// chain.Emit, so any attribution scheme bottoms out in trusting some set of
// emitting packages. It is the same trust structure as a curated token list,
// improved in one respect — the label cannot be forged, so the decision is made
// once per registry rather than once per token.
//
// A realm that wants no registry builds its own Emitter with a nil recorder. Its
// tokens still get distinct ids, and their events emit under grc20's own path —
// which is the point: opting out is visible in the stream rather than silent.

// EventRecorder records a token's events from the package that declares it, so
// the VM stamps that package's path onto them.
//
// Implementations live in /r/; grc20 imports none of them. An implementation
// must write id into the event as the "token" attribute itself and must not take
// that value from anywhere else — the whole guarantee is that the identifier on a
// stamped event is one this realm issued.
//
// attrs holds the remaining key/value pairs in order, already flattened. kind is
// one of this package's event constants; grc20 is the only caller.
type EventRecorder interface {
	RecordTokenEvent(id, kind string, attrs []string)
}

// Emitter is a realm-bound handle that issues token identifiers and, optionally,
// records the events of the tokens built from them. Obtain one from the realm
// that owns the counter — typically a registry — or build one for your own realm
// with NewEmitter.
//
// The counter stays in that realm. An Emitter carrying it in a field could be
// dereferenced into a copy from any package, and the copy would replay the
// sequence — the identity collision this design exists to prevent. Holding the
// realm's function instead means every copy advances the same counter, so no two
// calls return the same id.
//
// Every field is unexported and no method reaches recorder, so an Emitter is
// inert in the hands of its holder: it draws ids, which anyone may do, and
// nothing else. See the note above on why that matters.
type Emitter struct {
	packagePath string        // owning realm, captured at construction
	nextID      func() string // the owning realm's counter, advanced per call
	recorder    EventRecorder // the owning realm's event sink, or nil
}

// NewEmitter returns an Emitter bound to the caller's realm, drawing ids from
// nextID and routing events to recorder.
//
// rlm must be the caller's own captured cur (asserted via IsCurrent), so
// PackagePath() is unforgeable and a registry can accept only the ids its own
// counter produced; the leading unused int keeps rlm out of first position so
// this stays a non-crossing helper.
//
// nextID must advance state the caller owns. A degenerate one harms only its own
// realm: the resulting tokens carry that realm as EmitterPath(), so a registry
// accepting only its own ids rejects them.
//
// recorder may be nil, in which case tokens built from this Emitter emit under
// grc20's own pkg_path. Pass one only from the realm that declares it: routing a
// foreign realm's recorder here would stamp that realm's path on events it never
// caused.
func NewEmitter(_ int, rlm realm, nextID func() string, recorder EventRecorder) *Emitter {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}

	pkgPath := rlm.PkgPath()
	if pkgPath == "" {
		panic(ErrNotRealm)
	}

	if nextID == nil {
		panic(ErrNilIDFunc)
	}

	return &Emitter{packagePath: pkgPath, nextID: nextID, recorder: recorder}
}

// PackagePath returns the realm the Emitter is bound to.
func (e *Emitter) PackagePath() string { return e.packagePath }

// RecordsEvents reports whether tokens built from this Emitter emit under the
// bound realm's pkg_path rather than grc20's.
func (e *Emitter) RecordsEvents() bool { return e.recorder != nil }

// NextID advances the owning realm's counter and returns the new id.
func (e *Emitter) NextID() string {
	id := e.nextID()
	if !validID(id) {
		panic(ErrInvalidID)
	}

	return id
}

// validID reports whether id is a valid trailing segment. It shares validSymbol's
// charset because it is concatenated into Token.ID(): banning `.` `/` and
// whitespace keeps ids unambiguous for downstream parsers.
func validID(id string) bool {
	return validSlugText(id, MaxIDLen)
}
