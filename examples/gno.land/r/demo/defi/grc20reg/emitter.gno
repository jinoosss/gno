package grc20reg

import (
	"chain"

	"gno.land/p/demo/tokens/grc20"
)

// emitter is the sink grc20 calls to record a token's events. It carries no
// state; the only thing that matters about it is where its method is declared.
type emitter struct{}

var (
	canonicalEmitter = &emitter{}

	_ grc20.TokenEmitter = (*emitter)(nil)
)

// Emit emits one token event from this package, so the VM stamps
// this realm's path onto it.
//
// It repeats grc20's own fallback on purpose: calling a shared helper declared
// over there would put grc20's frame in front of chain.Emit and stamp grc20's
// path, which is the one thing this method exists to avoid.
//
// id is written as the "token" attribute here rather than taken from attrs.
// grc20 is the only caller — reaching this method requires reaching a field no
// package outside grc20 can name — and it passes the identifier bound to the
// token whose ledger just acted.
func (r *emitter) Emit(id, kind string, attrs []string) {
	all := make([]string, 0, len(attrs)+2)
	all = append(all, "token", id)
	all = append(all, attrs...)
	chain.Emit(kind, all...)
}
