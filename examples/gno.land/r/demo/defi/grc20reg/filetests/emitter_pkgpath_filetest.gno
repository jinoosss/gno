// PKGPATH: gno.land/r/demo/grc20emitpath

// The observable payoff of registry-owned emission: pkg_path.
//
// The VM stamps pkg_path from the package that calls chain.Emit, so a token that
// took its Emitter from the registry has every event labelled with the
// registry's path, and that label cannot be forged — a realm emitting for itself
// produces events under grc20's path instead. The two are trivially
// distinguishable in the stream, and Token.EventPath() reports which is which
// without having to read one.
package grc20emitpath

import (
	"gno.land/p/demo/tokens/grc20"
	"gno.land/r/demo/defi/grc20reg"
)

func selfID() string { return "0000001" }

func main(cur realm) {
	owned, ownedLedger := grc20.NewToken("Owned", "OWN", 6, grc20reg.Emitter(cross(cur)), cur)
	self, selfLedger := grc20.NewToken("Self", "SLF", 6, grc20.NewEmitter(0, cur, selfID, nil), cur)

	println("owned id:", owned.ID())
	println("owned events:", owned.EventPath())
	println("self  id:", self.ID())
	println("self  events:", self.EventPath())

	ownedLedger.Mint(cur.Address(), 1)
	selfLedger.Mint(cur.Address(), 1)
}

// Output:
// owned id: gno.land/r/demo/grc20emitpath.OWN.gno.land/r/demo/defi/grc20reg:0000001
// owned events: gno.land/r/demo/defi/grc20reg
// self  id: gno.land/r/demo/grc20emitpath.SLF.gno.land/r/demo/grc20emitpath:0000001
// self  events: gno.land/p/demo/tokens/grc20

// Events:
// [
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20emitpath.OWN.gno.land/r/demo/defi/grc20reg:0000001"
//       },
//       {
//         "key": "name",
//         "value": "Owned"
//       },
//       {
//         "key": "symbol",
//         "value": "OWN"
//       },
//       {
//         "key": "decimals",
//         "value": "6"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/defi/grc20reg"
//   },
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20emitpath.SLF.gno.land/r/demo/grc20emitpath:0000001"
//       },
//       {
//         "key": "name",
//         "value": "Self"
//       },
//       {
//         "key": "symbol",
//         "value": "SLF"
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
//         "value": "gno.land/r/demo/grc20emitpath.OWN.gno.land/r/demo/defi/grc20reg:0000001"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1y4j5mkkjel0n43knx9jt82hq4ndwe47nnwcc70"
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
//         "value": "gno.land/r/demo/grc20emitpath.SLF.gno.land/r/demo/grc20emitpath:0000001"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1y4j5mkkjel0n43knx9jt82hq4ndwe47nnwcc70"
//       },
//       {
//         "key": "value",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   }
// ]
