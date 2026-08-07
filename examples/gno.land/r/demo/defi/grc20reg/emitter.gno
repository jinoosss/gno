package grc20reg

import (
	"chain"
	"strconv"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/fqname/v0"
)

// This file makes grc20reg a grc20.Emitter: it issues token identifiers and
// records the events of the tokens that opted into it.
//
// A token realm opts in at construction:
//
//	Token, ledger := grc20.NewTokenWithEmitter("Foo", "FOO", 4, grc20reg.Emitter(), cur)
//	key := grc20reg.Register(cross(cur), Token, "")
//
// What that buys, and why it holds:
//
//   - Distinct identifiers. sequences below lives in this realm's package state
//     and is never returned to a caller, so it cannot be copied and replayed.
//     Two tokens from one realm therefore cannot share an identifier, which is
//     what made their event streams inseparable before.
//
//   - An unforgeable label on every event. tokenEmitter's methods call chain.Emit
//     from this package, so the VM stamps pkg_path = gno.land/r/demo/defi/grc20reg.
//     A counterfeit grc20.Emitter cannot borrow that: its events carry its own
//     path.
//
//   - An identifier on that event that this realm chose. The methods write the
//     "token" attribute from the identifier bound to the handle, never from an
//     argument, and grc20.TokenEmitter offers no free-form emit. Without that,
//     the label would be unforgeable while what it labels was not: any realm can
//     call Emitter().IssueToken for its own namespace, and a free-form emit would
//     then let it record an event carrying this realm's pkg_path under an
//     identifier belonging to somebody else. Together with the two points above,
//     a registry-stamped event is attributable to one identifier this realm
//     issued exactly once, to the realm that owns it. See grc20/emitter.gno for
//     what that does and does not attest.
//
//   - Provenance checkable from this realm's own records. issued below maps every
//     identifier this realm handed out to the realm it was handed to, so Register
//     verifies provenance without asking the token to describe its emitter — and
//     so without ever type-asserting or handing back a value that carries the
//     emitting capability. EmitterPath exposes the same record as a query, so a
//     consumer that missed the register event can still ask.
//
// Tokens built with grc20.NewToken still work and still register. They emit
// under grc20's own pkg_path and keep the ambiguity, which is the point: opting
// out is visible rather than silent.

type emitter struct{}

type tokenEmitter struct{ id string }

var (
	// realm path -> int64, the per-realm issuance counter. Package state, never
	// handed out: this is the difference between a counter that cannot be
	// replayed and one that can.
	sequences = avl.NewTree()

	// token identifier -> issuing realm path. Register reads this instead of
	// trusting anything the token reports about itself.
	issued = avl.NewTree()

	canonicalEmitter = &emitter{}
)

var (
	_ grc20.Emitter      = (*emitter)(nil)
	_ grc20.TokenEmitter = (*tokenEmitter)(nil)
)

// Emitter returns this realm as a grc20.Emitter, for grc20.NewTokenWithEmitter.
//
// Unlike handing out a counter, handing out this value grants nothing: it holds
// no state, and every method that mutates state runs here.
func Emitter() grc20.Emitter {
	return canonicalEmitter
}

// IssueToken assigns a fresh identifier to a token being created by the calling
// realm. It is a crossing method, so the creating realm is read from the live
// frame rather than taken as an argument — an argument could name any realm.
func (e *emitter) IssueToken(cur realm, symbol string) grc20.TokenEmitter {
	rlmPath := cur.Previous().PkgPath()
	if rlmPath == "" {
		panic("grc20reg: token issuer must be a realm")
	}

	n := int64(0)
	if v := sequences.Get(rlmPath); v != nil {
		n = v.(int64)
	}
	n = nextSequence(n)
	sequences.Set(rlmPath, n)

	id := rlmPath + "." + symbol + "." + strconv.FormatInt(n, 10)
	issued.Set(id, rlmPath)

	return &tokenEmitter{id: id}
}

// nextSequence advances n, skipping any value whose decimal form could also be
// produced by grc20.NewToken.
//
// A NewToken identifier ends in seqid.ID.String(), which is always exactly 7 or
// 13 characters; ours ends in a decimal number. The two only meet in the 7- and
// 13-digit bands, and n enters each band exactly at its lower bound, so
// multiplying past it is enough. Without this, a realm that had taken a million
// identifiers from this registry could build a NewToken whose id equals one of
// them and appear registry-issued to IssuedTo — unreachable in practice, but the
// point of these records is that they hold by construction rather than by
// arithmetic.
func nextSequence(n int64) int64 {
	n++
	switch len(strconv.FormatInt(n, 10)) {
	case 7, 13:
		n *= 10
	}
	return n
}

// TokenID returns the identifier this handle is permanently bound to.
func (t *tokenEmitter) TokenID() string { return t.id }

// EmitTransfer records a transfer of the token this handle is bound to. Called
// from this package, so the VM stamps this realm's path onto the event.
//
// The "token" attribute is written from the bound identifier rather than taken
// from the caller: holding a handle must not let a realm label an event with an
// identifier this registry issued to somebody else. The handle is bound to that
// one identifier for life, so a copy of it conveys no authority its holder did
// not already have.
func (t *tokenEmitter) EmitTransfer(from, to address, amount int64) {
	chain.Emit(
		grc20.TransferEvent,
		"token", t.id,
		"from", string(from),
		"to", string(to),
		"value", strconv.Itoa(int(amount)),
	)
}

// EmitApproval records an allowance change on the token this handle is bound to,
// under the same discipline as EmitTransfer.
func (t *tokenEmitter) EmitApproval(owner, spender address, amount int64) {
	chain.Emit(
		grc20.ApprovalEvent,
		"token", t.id,
		"owner", string(owner),
		"spender", string(spender),
		"value", strconv.Itoa(int(amount)),
	)
}

// IssuedTo returns the realm this registry issued id to, and whether it issued
// id at all.
func IssuedTo(id string) (string, bool) {
	v := issued.Get(id)
	if v == nil {
		return "", false
	}
	return v.(string), true
}

// EmitterPath returns the pkg_path that stamps the events of the token
// registered under key, and whether this registry can attest to it.
//
// This is the query form of the "emitter" attribute Register reports, with the
// same meaning, for consumers that were not listening at registration time. It
// attests only for tokens it issued: those carry this realm's path, established
// from its own record of what it handed out. Everything else is ("", false) —
// an unregistered key, a token built with grc20.NewToken that emits under
// grc20's own path, and one routed through some other registry are
// indistinguishable from here, since separating them would mean asking the
// token to describe its emitter, which is the one thing this design does not
// trust.
//
// A token this registry cannot attest for is not thereby suspect; it is a token
// whose event stream carries the ambiguity the registry exists to remove, and
// whose actual pkg_path a consumer must read off the events themselves.
func EmitterPath(key string) (string, bool) {
	token := Get(key)
	if token == nil {
		return "", false
	}
	rlmPath, _ := fqname.Parse(key)
	if !issuedHere(token.ID(), rlmPath) {
		return "", false
	}
	return selfPkgPath, true
}

// issuedHere reports whether this registry issued id, and issued it to rlmPath.
// Both Register and EmitterPath answer from this, so the two always agree on
// what "issued here" means.
func issuedHere(id, rlmPath string) bool {
	to, ok := IssuedTo(id)
	return ok && to == rlmPath
}

// selfPkgPath is this realm's own path: what the VM stamps on the events emitted
// from this package, and so what EmitterPath reports for a token that routes
// through this registry. Register derives the same value from cur.PkgPath()
// rather than from here; TestSelfPkgPathMatchesTheRealm keeps the two in step.
const selfPkgPath = "gno.land/r/demo/defi/grc20reg"
