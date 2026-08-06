package grc20reg

import (
	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/onbloc/identifier"
)

// The registry owns one persistent identifier.Generator in its package state and
// never returns it to a caller, so the counter that makes token ids unique can
// neither be copied nor replayed. issued records every id the registry minted
// and the realm it was minted for, so Register verifies provenance from the
// registry's own record rather than from anything the token claims about itself.
var (
	idGenerator *identifier.Generator

	// issued maps a minted token id -> the realm it was minted for.
	issued = avl.NewTree()

	canonicalIssuer = &issuer{}
)

var _ grc20.Issuer = (*issuer)(nil)

// issuer is the canonical grc20.Issuer. It carries no fields: all state lives in
// the package (idGenerator, issued), so copying the value grants a caller
// nothing — the copy defeats a struct-based generator has no target here.
type issuer struct{}

// Issuer returns the registry's canonical token-id issuer. Pass it to
// grc20.NewToken so the resulting id is minted by grc20reg and recorded for
// Register to verify:
//
//	Token, ledger := grc20.NewToken(name, symbol, decimals, grc20reg.Issuer(), cur)
//	key := grc20reg.Register(cross(cur), Token, "myslug")
func Issuer() grc20.Issuer {
	return canonicalIssuer
}

// IssueID mints a fresh token id for the calling realm. It is a crossing method,
// so the creating realm is read from the live frame (cur.Previous()) rather than
// trusted from an argument. The id is {creatingRealm}.{symbol}.{code}, where code
// comes from the registry's private generator, and is recorded in issued so
// Register can confirm the registry minted it.
func (e *issuer) IssueID(cur realm, symbol string) string {
	rlmPath := cur.Previous().PkgPath()
	if rlmPath == "" {
		panic("grc20reg: token issuer must be a realm")
	}

	id := rlmPath + "." + symbol + "." + idGenerator.NextID()
	issued.Set(id, rlmPath)
	return id
}

// IssuedTo reports the realm the registry minted id for, and whether the
// registry minted it at all. Register uses it to verify a token's id came from
// this registry's own generator.
func IssuedTo(id string) (string, bool) {
	v := issued.Get(id)
	if v == nil {
		return "", false
	}
	return v.(string), true
}
