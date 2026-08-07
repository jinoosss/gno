// PKGPATH: gno.land/r/demo/grc20counterfeit

// The registry hands out no Emitter, so its pkg_path cannot be borrowed.
//
// NewToken passes canonicalEmitter to grc20 itself, so the TokenEmitter is
// returned into this realm rather than into the caller's and cannot be kept on
// the way past. A realm wanting registry-labelled events has to supply an
// Emitter of its own to grc20.NewTokenWithEmitter — and that one emits from its
// own package, so the VM stamps its path, not ours.
package grc20counterfeit

import (
	"chain"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/r/demo/defi/grc20reg"
)

type fakeEmitter struct{}

func (f *fakeEmitter) IssueToken(cur realm, symbol string) grc20.TokenEmitter {
	return &fakeTokenEmitter{id: "gno.land/r/demo/grc20counterfeit." + symbol + ".1"}
}

type fakeTokenEmitter struct{ id string }

func (f *fakeTokenEmitter) TokenID() string { return f.id }

func (f *fakeTokenEmitter) Emit(kind string, attrs ...string) {
	chain.Emit(kind, attrs...)
}

func main(cur realm) {
	real, realLedger := grc20reg.NewToken(0, cur, "Real", "REAL", 6)
	fake, fakeLedger := grc20.NewTokenWithEmitter("Fake", "FAKE", 6, &fakeEmitter{}, cur)

	realLedger.Mint(cur.Address(), 1)
	fakeLedger.Mint(cur.Address(), 1)

	println("real id:", real.ID())
	println("fake id:", fake.ID())
}

// Events:
// [
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20counterfeit.REAL.1"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1kszxagrlpck0yrkn3xnrl36zvserjw22ll8fkr"
//       },
//       {
//         "key": "value",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/defi/grc20reg"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20counterfeit.FAKE.1"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1kszxagrlpck0yrkn3xnrl36zvserjw22ll8fkr"
//       },
//       {
//         "key": "value",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/grc20counterfeit"
//   }
// ]

// Output:
// real id: gno.land/r/demo/grc20counterfeit.REAL.1
// fake id: gno.land/r/demo/grc20counterfeit.FAKE.1
