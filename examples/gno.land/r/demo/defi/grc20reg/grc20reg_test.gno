package grc20reg

import (
	"strings"
	"testing"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/urequire/v0"
)

func TestRegistry(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/foo"))
	token, ledger := grc20.NewToken("TestToken", "TST", 4, Issuer(), cur)
	ledger.Mint(cur.Address(), 1234567)
	// The returned tokenKey is the slug alias, distinct from Token.ID().
	key := Register(cross(cur), token, "mySlug")
	urequire.Equal(t, "gno.land/r/demo/foo.mySlug", key)
	urequire.NotEqual(t, token.ID(), key)
	regToken := Get(key)
	urequire.True(t, regToken != nil, "expected to find a token") // fixme: use urequire.NotNil
	urequire.Equal(t, regToken.GetSymbol(), "TST")

	expected := `- **TestToken** - [gno.land/r/demo/foo](/r/demo/foo).mySlug - [info](/r/demo/grc20reg:gno.land/r/demo/foo.mySlug)
`
	got := Render("")
	urequire.True(t, strings.Contains(got, expected))
	// 404
	invalidToken := Get("0xdeadbeef")
	urequire.True(t, invalidToken == nil)

	got = Render("")
	urequire.True(t, strings.Contains(got, expected))

	expected = `# TestToken
- symbol: **TST**
- realm: [gno.land/r/demo/foo](/r/demo/foo).mySlug
- decimals: 4
- total supply: 1234567
`
	got = Render(key)
	urequire.Equal(t, expected, got)
}

func TestRegisterAliases(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/grc20reg_alias"))
	token, _ := grc20.NewToken("Aliased", "ALIAS", 4, Issuer(), cur)

	// The same token may be registered under several slugs (aliases).
	keyA := Register(cross(cur), token, "a")
	keyB := Register(cross(cur), token, "b")
	urequire.NotEqual(t, keyA, keyB)
	urequire.Equal(t, token.ID(), Get(keyA).ID())
	urequire.Equal(t, token.ID(), Get(keyB).ID())
}

func TestRegisterRejectsDuplicateSlug(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/grc20reg_dup"))
	first, _ := grc20.NewToken("First", "FIR", 4, Issuer(), cur)
	second, _ := grc20.NewToken("Second", "SEC", 4, Issuer(), cur)
	Register(cross(cur), first, "dup")

	// The same slug (tokenKey) is rejected, even for a different token.
	urequire.AbortsContains(t, cur, "token already registered", func() {
		Register(cross(cur), second, "dup")
	})
}

// foreignIssuer mints a namespaced-but-unrecorded id: it satisfies NewToken's
// namespace guard (id in the creating realm's path) yet the registry never
// recorded it, so Register must reject it.
type foreignIssuer struct{}

func (foreignIssuer) IssueID(cur realm, symbol string) string {
	return cur.Previous().PkgPath() + "." + symbol + ".foreign"
}

func TestRegisterRejectsForeignIssuer(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/grc20reg_foreign_gen"))
	// A token whose id came from an issuer other than the registry's own is
	// rejected — the registry has no record of it (IssuedTo == false). This is
	// what ties a registered token to the trusted issuer.
	token, _ := grc20.NewToken("Foreign", "FGN", 4, foreignIssuer{}, cur)

	urequire.AbortsContains(t, cur, "not issued by this registry", func() {
		Register(cross(cur), token, "")
	})
}

func TestRegisterRejectsTokenFromDifferentRealm(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/grc20reg_id_source"))
	token, _ := grc20.NewToken("Mismatch Token", "MISMATCH", 4, Issuer(), cur)

	// The id was issued to grc20reg_id_source; registering it from a different
	// realm is rejected because IssuedTo(id) != the registering realm.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/grc20reg_id_target"))
	urequire.AbortsContains(t, cur, "not issued by this registry for the registering realm", func() {
		Register(cross(cur), token, "")
	})
}

// Two tokens created by one realm with the same symbol get distinct
// identifiers, so their event streams can be told apart. This is the case that
// motivated the work: with a caller-supplied, replayable id they would collide.
func TestIssuerNeverReissuesAnIdentifier(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/issuedup"))
	first, _ := grc20.NewToken("Same", "DUP", 6, Issuer(), cur)
	second, _ := grc20.NewToken("Same", "DUP", 6, Issuer(), cur)
	urequire.NotEqual(t, first.ID(), second.ID(), "same-symbol tokens must not share an id")
}

// Identifiers stay inside the creating realm's namespace, and the registry
// records what it issued so Register can verify provenance from its own record.
func TestIdentifierIsNamespacedAndRecorded(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/issuens"))
	tok, _ := grc20.NewToken("Ns", "NS", 6, Issuer(), cur)

	urequire.True(t, strings.HasPrefix(tok.ID(), "gno.land/r/demo/issuens.NS."), "id must be namespaced to the creating realm")

	to, ok := IssuedTo(tok.ID())
	urequire.True(t, ok, "registry should have a record of the id it issued")
	urequire.Equal(t, "gno.land/r/demo/issuens", to)
}

// The attack that defeats a handed-out counter: copy the value the registry
// exposes and replay it (`a, b := *g, *g`). Here the counter lives in the
// registry's package state, so a copy of the stateless issuer handle carries
// none of it and still draws distinct ids.
func TestCopyingTheIssuerCannotReplayAnIdentifier(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/issuecopy"))

	snapshot := *canonicalIssuer // the move that would break a struct-based generator

	viaRegistry, _ := grc20.NewToken("A", "CP", 6, Issuer(), cur)
	viaCopy, _ := grc20.NewToken("B", "CP", 6, &snapshot, cur)

	urequire.NotEqual(t, viaRegistry.ID(), viaCopy.ID(), "a copied issuer must not replay an identifier")
}

func TestValidateSlug(cur realm, t *testing.T) {
	// Valid slugs — should not panic
	valid := []string{"mytoken", "my-token", "my_token", "Token123", "a", "A-B_c", strings.Repeat("a", maxSlugLen)}
	for _, slug := range valid {
		validateSlug(slug) // no panic = pass
	}
}

func TestValidateSlugPanicsOnTooLong(cur realm, t *testing.T) {
	defer func() { recover() }()
	validateSlug(strings.Repeat("a", maxSlugLen+1))
	t.Errorf("should have panicked")
}

func TestValidateSlugPanicsOnSpace(cur realm, t *testing.T) {
	defer func() { recover() }()
	validateSlug("has space")
	t.Errorf("should have panicked")
}

func TestValidateSlugPanicsOnDot(cur realm, t *testing.T) {
	defer func() { recover() }()
	validateSlug("has.dot")
	t.Errorf("should have panicked")
}

func TestValidateSlugPanicsOnSlash(cur realm, t *testing.T) {
	defer func() { recover() }()
	validateSlug("has/slash")
	t.Errorf("should have panicked")
}

func TestValidateSlugPanicsOnBrackets(cur realm, t *testing.T) {
	defer func() { recover() }()
	validateSlug("[brackets]")
	t.Errorf("should have panicked")
}

func TestValidateSlugPanicsOnParens(cur realm, t *testing.T) {
	defer func() { recover() }()
	validateSlug("(parens)")
	t.Errorf("should have panicked")
}

func TestValidateSlugPanicsOnInjection(cur realm, t *testing.T) {
	defer func() { recover() }()
	validateSlug(`) [Claim](https://evil.com`)
	t.Errorf("should have panicked")
}

func TestRegisterRejectsNilToken(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/grc20reg_nil"))
	urequire.AbortsContains(t, cur, "nil token", func() {
		Register(cross(cur), nil, "")
	})
}
