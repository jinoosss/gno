// PKGPATH: gno.land/r/demo/grc20capture

// The capture attack, and why it no longer reaches anything.
//
// The hand-off used to run through interfaces the creating realm implemented, so
// the realm saw — and could keep — the handle grc20 was about to bind, and could
// then record a Transfer with no ledger behind it under the registry's pkg_path:
//
//	func (w *capturing) IssueToken(cur realm, symbol string) grc20.TokenEmitter {
//		h := grc20reg.Emitter().IssueToken(cross(cur), symbol)
//		w.captured = h
//		return h
//	}
//
// grc20.Emitter is now a concrete struct holding the recorder in an unexported
// field. The realm below keeps the very handle NewToken consumed, and the handle
// is inert: PackagePath, RecordsEvents and NextID are its whole surface, and
// reaching past them is a compile error rather than a runtime check. Drawing
// another id still works — any realm may call grc20reg.Emitter as often as it
// likes — but the counter only advances, so it is a second token, not a replay.
package grc20capture

import (
	"gno.land/p/demo/tokens/grc20"
	"gno.land/r/demo/defi/grc20reg"
)

type capturing struct{ captured *grc20.Emitter }

func main(cur realm) {
	w := &capturing{}
	w.captured = grc20reg.Emitter(cross(cur))

	tok, _ := grc20.NewToken("Phantom", "PHM", 4, w.captured, cur)
	grc20reg.Register(cross(cur), tok, "")

	// The capture is real: this is the registry's own handle, still held.
	println("captured the registry handle:", w.captured.PackagePath())
	println("which records events:", w.captured.RecordsEvents())

	// And the whole of what it can do. There is no third method.
	println("still drawing ids:", w.captured.NextID())

	// Reusing it builds a distinct token, not a duplicate of the first.
	shadow, _ := grc20.NewToken("Shadow", "PHM", 4, w.captured, cur)
	println("distinct ids:", tok.ID() != shadow.ID())

	// No Transfer was recorded above, because none could be. The ledger is the
	// only thing that emits, and nothing moved.
	println("total supply:", tok.TotalSupply())
	println("balance:", tok.BalanceOf(cur.Address()))
}

// Output:
// captured the registry handle: gno.land/r/demo/defi/grc20reg
// which records events: true
// still drawing ids: 0000002
// distinct ids: true
// total supply: 0
// balance: 0

// Events:
// [
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20capture.PHM.gno.land/r/demo/defi/grc20reg:0000001"
//       },
//       {
//         "key": "name",
//         "value": "Phantom"
//       },
//       {
//         "key": "symbol",
//         "value": "PHM"
//       },
//       {
//         "key": "decimals",
//         "value": "4"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/defi/grc20reg"
//   },
//   {
//     "type": "register",
//     "attrs": [
//       {
//         "key": "token_path",
//         "value": "gno.land/r/demo/grc20capture.PHM"
//       },
//       {
//         "key": "token_id",
//         "value": "gno.land/r/demo/grc20capture.PHM.gno.land/r/demo/defi/grc20reg:0000001"
//       },
//       {
//         "key": "pkgpath",
//         "value": "gno.land/r/demo/grc20capture"
//       },
//       {
//         "key": "slug",
//         "value": ""
//       },
//       {
//         "key": "symbol",
//         "value": "PHM"
//       },
//       {
//         "key": "emitter",
//         "value": "gno.land/r/demo/defi/grc20reg"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/defi/grc20reg"
//   },
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20capture.PHM.gno.land/r/demo/defi/grc20reg:0000003"
//       },
//       {
//         "key": "name",
//         "value": "Shadow"
//       },
//       {
//         "key": "symbol",
//         "value": "PHM"
//       },
//       {
//         "key": "decimals",
//         "value": "4"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/defi/grc20reg"
//   }
// ]
