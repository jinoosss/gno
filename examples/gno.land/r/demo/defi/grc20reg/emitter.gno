package grc20reg

import (
	"chain"

	"gno.land/p/demo/tokens/grc20"
)

// This file makes grc20reg a grc20.EventRecorder: it records the events of every
// token whose id it issued, so those events carry this realm's pkg_path.
//
// A token realm opts in at construction, by taking its Emitter from here:
//
//	Token, ledger := grc20.NewToken("Foo", "FOO", 4, grc20reg.Emitter(cross(cur)), cur)
//	key := grc20reg.Register(cross(cur), Token, "")
//
// What that buys, and why it holds:
//
//   - Distinct identifiers. idSeq lives in this realm's package state and is
//     never returned to a caller — only nextIDSeq, which advances it, leaves.
//     Two tokens from one realm therefore cannot share an identifier, which is
//     what made their event streams inseparable before.
//
//   - An unforgeable label on every event. recordEvent calls chain.Emit from this
//     package, so the VM stamps pkg_path = gno.land/r/demo/defi/grc20reg. A realm
//     that builds its own grc20.Emitter cannot borrow that: its events carry its
//     own path, and its tokens are refused by Register.
//
//   - An identifier on that event that this realm issued. grc20 writes the
//     "token" attribute from the id it bound to the token at construction, which
//     came from nextIDSeq one call earlier, and that id embeds the creating
//     realm's own path — bound under IsCurrent, so unforgeable. A stamped event
//     is therefore attributable to one identifier this realm handed out exactly
//     once, to the realm named in it.
//
//   - No handle to abuse. The recorder below never leaves this realm: Emitter()
//     returns a *grc20.Emitter, which keeps it in an unexported field that
//     nothing outside grc20 can reach, and grc20 reaches it only from
//     Token.emit. A realm that keeps the Emitter it passed to NewToken holds an
//     inert value — it can draw further ids, which it could do anyway, and
//     cannot record a single event. See grc20/emitter.gno for the capture attack
//     this closes.
//
// Tokens built against an Emitter from somewhere else still work. They emit
// under that realm's path (or grc20's, for an Emitter with no recorder) and are
// not registrable here, which is the point: opting out is visible rather than
// silent.

// recorder is the sink grc20 calls to record a token's events. It carries no
// state; everything it needs arrives as arguments, and the only thing that
// matters about it is where its method is declared.
type recorder struct{}

var (
	canonicalRecorder = &recorder{}

	_ grc20.EventRecorder = (*recorder)(nil)
)

// RecordTokenEvent emits one token event from this package, so the VM stamps
// this realm's path onto it.
//
// The body repeats grc20's own fallback on purpose. Calling a shared helper
// declared over there would put grc20's frame in front of chain.Emit and stamp
// grc20's path, which is the one thing this method exists to avoid.
//
// id is written as the "token" attribute here rather than taken from attrs:
// grc20 passes the identifier bound to the token whose ledger just acted, and
// this method has no other source for it. kind and attrs come from grc20's own
// vocabulary — grc20 is the only caller, because reaching this method requires
// reaching a field no package outside grc20 can name.
func (r *recorder) RecordTokenEvent(id, kind string, attrs []string) {
	all := make([]string, 0, len(attrs)+2)
	all = append(all, "token", id)
	all = append(all, attrs...)
	chain.Emit(kind, all...)
}
