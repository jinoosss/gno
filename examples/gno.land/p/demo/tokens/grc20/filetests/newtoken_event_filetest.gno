// PKGPATH: gno.land/r/demo/grc20dupsignal

// This filetest is the reference for the detection rule the NewToken event
// enables. The realm below builds its own Emitter over a degenerate nextID that
// returns one constant, so both tokens end up with the same Token.ID() and their
// Transfer events are indistinguishable — the long-standing event-provenance
// ambiguity, in the only form still reachable.
//
// A realm can only do this to itself. The id embeds the Emitter's own package
// path, bound under IsCurrent, so these ids are visibly self-issued and a
// registry that accepts only its own is unaffected; and the events carry grc20's
// pkg_path rather than a registry's, so a consumer filtering on registries never
// sees them.
//
// What changes for a consumer that does look is that the ambiguity is
// *announced*. Two NewToken events carry the same "token" value, which is a
// complete signal: NewToken is the only way a Token can exist (Token's fields are
// unexported), so an indexer watching this event sees every token that will ever
// emit. On the second duplicate announcement it should flag the realm and stop
// trusting its token events.
package grc20dupsignal

import (
	"gno.land/p/demo/tokens/grc20"
)

// A well-behaved nextID advances state this realm owns; this one does not
// advance at all.
func sameIDForever() string { return "0000000" }

func main(cur realm) {
	first, firstLedger := newToken(cur)
	second, secondLedger := newToken(cur)

	println("same id:", first.ID() == second.ID())
	println("events emitted by:", first.EventPath())

	// Two independent ledgers, one identifier: these Transfers cannot be
	// attributed to either object from the event stream alone.
	firstLedger.Mint(cur.Address(), 1)
	secondLedger.Mint(cur.Address(), 999999)
}

func newToken(cur realm) (*grc20.Token, *grc20.PrivateLedger) {
	return grc20.NewToken("Same", "DUP", 6, grc20.NewEmitter(0, cur, sameIDForever, nil), cur)
}

// Output:
// same id: true
// events emitted by: gno.land/p/demo/tokens/grc20

// Events:
// [
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20dupsignal.DUP.gno.land/r/demo/grc20dupsignal:0000000"
//       },
//       {
//         "key": "name",
//         "value": "Same"
//       },
//       {
//         "key": "symbol",
//         "value": "DUP"
//       },
//       {
//         "key": "decimals",
//         "value": "6"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   },
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20dupsignal.DUP.gno.land/r/demo/grc20dupsignal:0000000"
//       },
//       {
//         "key": "name",
//         "value": "Same"
//       },
//       {
//         "key": "symbol",
//         "value": "DUP"
//       },
//       {
//         "key": "decimals",
//         "value": "6"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20dupsignal.DUP.gno.land/r/demo/grc20dupsignal:0000000"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1k29lxz0d8gx7m94n032ulum875p7gg0kduus5m"
//       },
//       {
//         "key": "value",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20dupsignal.DUP.gno.land/r/demo/grc20dupsignal:0000000"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1k29lxz0d8gx7m94n032ulum875p7gg0kduus5m"
//       },
//       {
//         "key": "value",
//         "value": "999999"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   }
// ]
