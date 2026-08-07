package grc20reg

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

// Two tokens created by one realm with the same symbol get distinct identifiers,
// so their event streams can be told apart. This is the case that motivated the
// whole exercise: with grc20.NewToken and a reused seqid they would collide.
func TestEmitterNeverReissuesAnIdentifier(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/emitdup"))

	first, _ := grc20.NewTokenWithEmitter("Same", "DUP", 6, Emitter(), cur)
	second, _ := grc20.NewTokenWithEmitter("Same", "DUP", 6, Emitter(), cur)

	t.Log("first :", first.ID())
	t.Log("second:", second.ID())
	uassert.NotEqual(t, first.ID(), second.ID())
}

// Identifiers stay inside the creating realm's namespace, so one realm cannot
// obtain an identifier that appears to belong to another.
func TestIdentifierIsNamespacedToTheCreatingRealm(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/emitns"))
	tok, _ := grc20.NewTokenWithEmitter("Ns", "NS", 6, Emitter(), cur)

	uassert.True(t, strings.HasPrefix(tok.ID(), "gno.land/r/demo/emitns.NS."))

	to, ok := IssuedTo(tok.ID())
	urequire.True(t, ok, "registry should have a record of the id it issued")
	uassert.Equal(t, "gno.land/r/demo/emitns", to)
}

// The attack that defeats a handed-out counter: copy the value the registry
// returns and replay it. Here the counter lives in the registry's package state,
// so a copy of the returned handle carries none of it.
func TestCopyingTheEmitterCannotReplayAnIdentifier(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/emitcopy"))

	snapshot := *canonicalEmitter // the move that breaks a struct-based generator

	viaRegistry, _ := grc20.NewTokenWithEmitter("A", "CP", 6, Emitter(), cur)
	viaCopy, _ := grc20.NewTokenWithEmitter("B", "CP", 6, &snapshot, cur)

	t.Log("via registry:", viaRegistry.ID())
	t.Log("via copy    :", viaCopy.ID())
	uassert.NotEqual(t, viaRegistry.ID(), viaCopy.ID())
}

// Register reports whether this registry issued the identifier, read from its own
// record rather than from anything the token claims about itself.
func TestRegisterReportsWhetherTheRegistryIssuedTheIdentifier(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/emitowned"))
	owned, _ := grc20.NewTokenWithEmitter("Owned", "OWN", 6, Emitter(), cur)
	Register(cross(cur), owned, "")
	to, ok := IssuedTo(owned.ID())
	uassert.True(t, ok)
	uassert.Equal(t, "gno.land/r/demo/emitowned", to)

	// A legacy token: created without an emitter, still registers, no record.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/emitlegacy"))
	legacy, _ := grc20.NewToken("Legacy", "LEG", 6, 0, cur)
	Register(cross(cur), legacy, "")
	_, ok = IssuedTo(legacy.ID())
	uassert.False(t, ok, "a token grc20 identified itself must not appear as registry-issued")
}

// The register event says which kind of token was registered, but only to
// whoever was listening. EmitterPath answers the same question afterwards, from
// the same records, so a consumer that arrived late is not stuck trusting what
// the token says about itself.
func TestEmitterPathReportsWhoStampsTheEvents(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/emitpathowned"))
	owned, _ := grc20.NewTokenWithEmitter("Owned", "OWN", 6, Emitter(), cur)
	ownedKey := Register(cross(cur), owned, "")

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/emitpathlegacy"))
	legacy, _ := grc20.NewToken("Legacy", "LEG", 6, 0, cur)
	legacyKey := Register(cross(cur), legacy, "")

	path, ok := EmitterPath(ownedKey)
	uassert.True(t, ok, "a token this registry issued must be attestable")
	uassert.Equal(t, selfPkgPath, path)

	// The registry can only attest for what it issued. A token that emits for
	// itself and one routed through a different registry are the same answer
	// here, because telling them apart would mean trusting the token.
	path, ok = EmitterPath(legacyKey)
	uassert.False(t, ok, "a token grc20 identified itself must not be attested")
	uassert.Equal(t, "", path)

	path, ok = EmitterPath("gno.land/r/demo/nosuchrealm.NONE")
	uassert.False(t, ok)
	uassert.Equal(t, "", path)
}

// selfPkgPath is written out rather than read from a frame, so pin it to the
// value Register derives from the live one. cur is this realm's own here: no
// testing.SetRealm has run.
func TestSelfPkgPathMatchesTheRealm(cur realm, t *testing.T) {
	uassert.Equal(t, cur.PkgPath(), selfPkgPath)
}

// A NewToken id ends in seqid.ID.String(), always exactly 7 or 13 characters, so
// a decimal sequence of either width is one grc20.NewToken could reproduce.
// nextSequence steps over both bands, which is what lets IssuedTo hold by
// construction instead of by "nobody will ever mint a million tokens".
func TestNextSequenceSkipsWidthsNewTokenCouldReproduce(t *testing.T) {
	uassert.Equal(t, int64(1), nextSequence(0))
	uassert.Equal(t, int64(999999), nextSequence(999998))

	// 1000000 is seqid.ID(1<<30).String(); the whole 7-digit band goes with it.
	uassert.Equal(t, int64(10000000), nextSequence(999999))
	uassert.Equal(t, int64(10000000000000), nextSequence(999999999999))

	for _, n := range []int64{0, 999999, 999999999999, 10000000, 42} {
		next := nextSequence(n)
		width := len(strconv.FormatInt(next, 10))
		uassert.True(t, width != 7 && width != 13, "sequence must not land on a seqid width")
		uassert.True(t, next > n, "sequence must advance")
	}
}
