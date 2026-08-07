// PKGPATH: gno.land/r/demo/grc20forge

// Emitter() and IssueToken are public, so any realm can obtain a handle for its
// own namespace without going through grc20.NewTokenWithEmitter, and record
// events carrying this registry's pkg_path with no ledger behind them.
//
// That is allowed, and is not the ambiguity this registry exists to remove: the
// realm already owns every ledger in its own namespace and can mint at will, so
// recording events for an id it was issued grants it nothing new.
//
// What must not be possible is labelling such an event with an identifier the
// registry issued to somebody else — that would put a forged Transfer for a
// victim's token under the registry's own path, and consumers filter on exactly
// that path. TokenEmitter therefore has no free-form emit: the handle writes the
// "token" attribute from the id it is bound to, so the attempt below to speak
// for gno.land/r/demo/grc20victim comes out labelled with the forger's own id.
package grc20forge

import (
	"gno.land/r/demo/defi/grc20reg"
)

func main(cur realm) {
	handle := grc20reg.Emitter().IssueToken(cross(cur), "EVIL")
	println("bound to:", handle.TokenID())

	// The values are the caller's to choose; the identifier is not.
	handle.EmitTransfer("g1victim", "g1attacker", 1000000)
}

// Output:
// bound to: gno.land/r/demo/grc20forge.EVIL.1

// Events:
// [
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/demo/grc20forge.EVIL.1"
//       },
//       {
//         "key": "from",
//         "value": "g1victim"
//       },
//       {
//         "key": "to",
//         "value": "g1attacker"
//       },
//       {
//         "key": "value",
//         "value": "1000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/defi/grc20reg"
//   }
// ]
