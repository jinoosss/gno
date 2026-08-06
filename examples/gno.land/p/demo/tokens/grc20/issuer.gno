package grc20

// This file defines the opt-in hand-off that lets a registry realm issue a
// token's identity without ever exposing the counter that backs it.
//
// # The problem
//
// Two Token objects created in one realm can share a Token.ID() when the
// trailing id is caller-supplied, so their Mint/Burn/Transfer/Approval events
// (which carry that id in the "token" attribute) cannot be told apart by a
// consumer reconstructing balances.
//
// # Why it cannot be fixed inside grc20
//
// Distinguishing the objects requires an identifier no realm can reissue, which
// requires state that survives across transactions. A /p/ package holds no
// persistent state, so grc20 cannot own a counter. Any counter grc20 is *handed*
// — as a struct or a pointer to one — can be copied by the caller
// (`snapshot := *gen`) and replayed to mint a second token carrying the first
// one's identifier. Handing out the counter is handing out the ability to
// defeat it.
//
// # The hand-off
//
// So the state must stay inside a realm the creating realm cannot reach into. A
// Token may therefore be created against an Issuer — a registry realm that
// issues the token's identifier from a counter held in its own package state.
// Because that state is never returned to the caller, it cannot be copied or
// replayed. NewToken calls IssueID itself, so the caller never holds a handle to
// reuse across two tokens; and IssueID is a crossing method, so the registry
// authenticates the creating realm from the live frame (cur.Previous()) rather
// than from an argument.
//
// # What grc20 keeps
//
// Unlike a registry that also owns emission, an Issuer only mints the id: grc20
// still emits every event under its own package path, so a token stays a plain,
// registry-agnostic grc20 no matter which registry issued its id. NewToken
// additionally checks the issued id falls inside the creating realm's namespace,
// so Token.ID() keeps its realm-prefixed guarantee regardless of which Issuer is
// supplied — a counterfeit Issuer cannot make a token claim another realm's
// identity.

// Issuer is a registry realm that issues unforgeable, single-use token
// identifiers. Implementations live in /r/; grc20 imports none of them.
//
// IssueID must be a crossing method so the implementation authenticates the
// creating realm from cur.Previous() rather than from an argument. It must
// return a distinct identifier on every call, derived from state the caller
// cannot obtain — package-level state, never a returned handle — and prefixed
// with the creating realm's package path so the id stays in that realm's
// namespace.
type Issuer interface {
	IssueID(cur realm, symbol string) string
}
