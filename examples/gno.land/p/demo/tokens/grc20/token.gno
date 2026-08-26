package grc20

import (
	"chain"
	"math"
	"math/overflow"
	"strconv"

	"gno.land/p/nt/ufmt/v0"
)

// NewToken creates a Token whose origRealm is bound to the calling realm.
// rlm must be the caller's own captured cur (asserted via rlm.IsCurrent()),
// and rlm.PkgPath() — the calling realm itself — becomes the Token's
// origRealm. Token.ID() returns origRealm + "." + symbol + "." + emitterPath + ":" + id
// (e.g. "gno.land/r/demo/defi/foo20.FOO.gno.land/r/demo/defi/grc20reg:0000001").
//
// Because IsCurrent runtime-validates that rlm came from the live crossing
// frame, origRealm is unforgeable: an external realm cannot fabricate a Token
// claiming to belong to a different package.
//
// em supplies the trailing id segment and, when it carries a recorder, the realm
// that records this token's events; see emitter.gno for why copying an Emitter
// cannot yield a duplicate id and why holding one grants no ability to emit.
// em.PackagePath() becomes the Token's EmitterPath(), so a registry accepts only
// tokens whose ids came from its own counter. Take em from the registry you
// intend to register with:
//
//	em := grc20reg.Emitter(cross(cur))
//	Token, ledger := grc20.NewToken("Foo", "FOO", 4, em, cur)
//	grc20reg.Register(cross(cur), Token, "")
//
// A realm that will not register its token can build its own Emitter instead.
//
// Every successful call emits a NewToken event carrying the resulting
// Token.ID(), through the same route as the token's later events. Because
// Token's fields are unexported, NewToken is the only way a Token can come into
// existence, so this event makes token creation fully observable. A well-behaved
// Emitter never repeats an id, so an indexer that sees the same Token.ID()
// announced twice knows the realm's nextID is degenerate: two independent
// ledgers share one identifier, and every later Mint/Burn/Transfer/Approval
// carrying that id is ambiguous. Such a realm is emitting untrustworthy events
// and should be flagged or ignored wholesale.
func NewToken(name, symbol string, decimals int, em *Emitter, rlm realm) (*Token, *PrivateLedger) {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
	pkgPath := rlm.PkgPath()
	if pkgPath == "" {
		panic(ErrNotRealm)
	}
	if !validName(name) {
		panic(ErrInvalidName)
	}
	if !validSymbol(symbol) {
		panic(ErrInvalidSymbol)
	}
	if decimals < 0 || decimals > MaxDecimals {
		panic(ErrInvalidDecimals)
	}
	// A zero-value &Emitter{} is constructible from outside this package,
	// so check the field, not just the pointer.
	if em == nil || em.nextID == nil {
		panic(ErrNilEmitter)
	}
	// The emitter's path is part of the id, not just a side field. Two issuers
	// can hand out the same code — a realm can read a registry-issued code off
	// chain state and have its own emitter return it verbatim — and events
	// carry only the id, so without the issuer in it the two tokens would be
	// indistinguishable to a consumer.
	id := pkgPath + "." + symbol + "." + em.packagePath + ":" + em.NextID()
	ledger := &PrivateLedger{}
	token := &Token{
		id:          id,
		emitterPath: em.packagePath,
		recorder:    em.recorder,
		name:        name,
		symbol:      symbol,
		decimals:    decimals,
		ledger:      ledger,
	}
	ledger.token = token

	token.emit(
		NewTokenEvent,
		"name", name,
		"symbol", symbol,
		"decimals", strconv.Itoa(decimals),
	)

	return token, ledger
}

// emit records one of this token's events, routing it through the emitter realm
// when the token has one so the VM stamps that realm's path, and falling back to
// grc20's own path otherwise.
//
// The "token" attribute is written from tok.id at the far end rather than passed
// through by the caller of the ledger: what a stamped event names is always the
// identifier the emitter realm issued for this very token. attrs carries the
// remaining pairs in order, so both routes produce the same attribute layout.
//
// This is the only path from a Token to its recorder, and it is unexported. A
// realm that kept the Emitter it passed to NewToken still cannot reach the
// recorder, which is what stops a captured handle from recording transfers no
// ledger performed — see emitter.gno.
func (tok *Token) emit(kind string, attrs ...string) {
	if tok.recorder != nil {
		tok.recorder.RecordTokenEvent(tok.id, kind, attrs)
		return
	}
	all := make([]string, 0, len(attrs)+2)
	all = append(all, "token", tok.id)
	all = append(all, attrs...)
	chain.Emit(kind, all...)
}

// validName reports whether name is a valid display name: non-empty,
// within MaxNameLen, and contains no control characters (any rune
// below 0x20 or 0x7f). Permits Unicode letters, digits, punctuation,
// and spaces — name is purely a display field.
func validName(name string) bool {
	if name == "" || len(name) > MaxNameLen {
		return false
	}
	for _, c := range name {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	return true
}

// validSymbol reports whether s is valid slug-compatible metadata: non-empty,
// within MaxSymbolLen, and consists only of [A-Za-z0-9_-].
func validSymbol(s string) bool {
	return validSlugText(s, MaxSymbolLen)
}

// validSlugText reports whether s is non-empty, at most maxLen bytes, and
// consists only of [A-Za-z0-9_-]. Shared by validSymbol and validID, which
// differ only in their length cap.
func validSlugText(s string, maxLen int) bool {
	if s == "" || len(s) > maxLen {
		return false
	}
	for _, c := range s {
		if !isAlnum(c) && c != '_' && c != '-' {
			return false
		}
	}
	return true
}

func isAlnum(c rune) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// GetName returns the name of the token.
func (tok Token) GetName() string { return tok.name }

// GetSymbol returns the symbol of the token.
func (tok Token) GetSymbol() string { return tok.symbol }

// GetDecimals returns the number of decimals used to get the token's precision.
func (tok Token) GetDecimals() int { return tok.decimals }

// TotalSupply returns the total supply of the token.
func (tok Token) TotalSupply() int64 { return tok.ledger.totalSupply }

// KnownAccounts returns the number of known accounts in the bank.
func (tok Token) KnownAccounts() int { return tok.ledger.balances.Size() }

// ID returns the Identifier of the token.
// It is composed of the original realm, the symbol, and the provided id.
func (tok *Token) ID() string {
	return tok.id
}

// EmitterPath returns the package path of the realm whose Emitter produced the
// trailing segment of the token's id.
func (tok *Token) EmitterPath() string {
	return tok.emitterPath
}

// EventPath returns the package path the VM stamps on this token's events, which
// is what a consumer filters on. It is EmitterPath() when the token's Emitter
// carried a recorder, and grc20's own path otherwise — a token that opted out of
// a registry is thereby visible as such rather than silently ambiguous.
func (tok *Token) EventPath() string {
	if tok.recorder == nil {
		return PackagePath
	}
	return tok.emitterPath
}

// HasAddr checks if the specified address is a known account in the bank.
func (tok Token) HasAddr(addr address) bool {
	return tok.ledger.hasAddr(addr)
}

// BalanceOf returns the balance of the specified address.
func (tok Token) BalanceOf(addr address) int64 {
	return tok.ledger.balanceOf(addr)
}

// Allowance returns the allowance of the specified owner and spender.
func (tok Token) Allowance(owner, spender address) int64 {
	return tok.ledger.allowance(owner, spender)
}

func (tok Token) RenderHome() string {
	str := ""
	str += ufmt.Sprintf("# %s ($%s)\n\n", tok.name, tok.symbol)
	str += ufmt.Sprintf("* **Decimals**: %d\n", tok.decimals)
	str += ufmt.Sprintf("* **Total supply**: %d\n", tok.ledger.totalSupply)
	str += ufmt.Sprintf("* **Known accounts**: %d\n", tok.KnownAccounts())
	return str
}

// SpendAllowance decreases the allowance of the specified owner and spender.
func (led *PrivateLedger) SpendAllowance(owner, spender address, amount int64) error {
	if !owner.IsValid() || !spender.IsValid() {
		return ErrInvalidAddress
	}

	if amount < 0 {
		return ErrInvalidAmount
	}
	// do nothing
	if amount == 0 {
		return nil
	}

	currentAllowance := led.allowance(owner, spender)
	if currentAllowance < amount {
		return ErrInsufficientAllowance
	}

	key := allowanceKey(owner, spender)
	newAllowance := overflow.Sub64p(currentAllowance, amount)

	if newAllowance == 0 {
		led.allowances.Remove(key)
	} else {
		led.allowances.Set(key, newAllowance)
	}

	return nil
}

// Transfer transfers tokens from the specified from address to the specified to address.
func (led *PrivateLedger) Transfer(from, to address, amount int64) error {
	if !from.IsValid() {
		return ErrInvalidAddress
	}
	if !to.IsValid() {
		return ErrInvalidAddress
	}
	if from == to {
		return ErrCannotTransferToSelf
	}
	if amount < 0 {
		return ErrInvalidAmount
	}

	var (
		toBalance   = led.balanceOf(to)
		fromBalance = led.balanceOf(from)
	)

	if fromBalance < amount {
		return ErrInsufficientBalance
	}

	var (
		newToBalance   = overflow.Add64p(toBalance, amount)
		newFromBalance = overflow.Sub64p(fromBalance, amount)
	)

	led.balances.Set(string(to), newToBalance)

	if newFromBalance == 0 {
		led.balances.Remove(string(from))
	} else {
		led.balances.Set(string(from), newFromBalance)
	}

	led.token.emit(
		TransferEvent,
		"from", from.String(),
		"to", to.String(),
		"value", strconv.Itoa(int(amount)),
	)

	return nil
}

// TransferFrom transfers tokens from the specified owner to the specified to address.
// It first checks if the owner has sufficient balance and then decreases the allowance.
func (led *PrivateLedger) TransferFrom(owner, spender, to address, amount int64) error {
	if amount < 0 {
		return ErrInvalidAmount
	}

	if !owner.IsValid() || !to.IsValid() {
		return ErrInvalidAddress
	}

	if led.balanceOf(owner) < amount {
		return ErrInsufficientBalance
	}

	// The check above guarantees that Transfer will succeed, ensuring
	// atomicity for the subsequent operations.
	if err := led.SpendAllowance(owner, spender, amount); err != nil {
		return err
	}

	if err := led.Transfer(owner, to, amount); err != nil {
		return err
	}

	return nil
}

// Approve sets the allowance of the specified owner and spender.
func (led *PrivateLedger) Approve(owner, spender address, amount int64) error {
	if !owner.IsValid() || !spender.IsValid() {
		return ErrInvalidAddress
	}
	if amount < 0 {
		return ErrInvalidAmount
	}

	led.allowances.Set(allowanceKey(owner, spender), amount)

	led.token.emit(
		ApprovalEvent,
		"owner", string(owner),
		"spender", string(spender),
		"value", strconv.Itoa(int(amount)),
	)

	return nil
}

// Mint increases the total supply of the token and adds the specified amount to the specified address.
func (led *PrivateLedger) Mint(addr address, amount int64) error {
	if !addr.IsValid() {
		return ErrInvalidAddress
	}
	if amount < 0 {
		return ErrInvalidAmount
	}

	// limit amount to MaxInt64 - totalSupply
	if amount > overflow.Sub64p(math.MaxInt64, led.totalSupply) {
		return ErrMintOverflow
	}

	led.totalSupply += amount
	currentBalance := led.balanceOf(addr)
	newBalance := overflow.Add64p(currentBalance, amount)

	led.balances.Set(string(addr), newBalance)

	led.token.emit(
		TransferEvent,
		"from", "",
		"to", string(addr),
		"value", strconv.Itoa(int(amount)),
	)

	return nil
}

// Burn decreases the total supply of the token and subtracts the specified amount from the specified address.
func (led *PrivateLedger) Burn(addr address, amount int64) error {
	if !addr.IsValid() {
		return ErrInvalidAddress
	}
	if amount < 0 {
		return ErrInvalidAmount
	}

	currentBalance := led.balanceOf(addr)
	if currentBalance < amount {
		return ErrInsufficientBalance
	}

	led.totalSupply = overflow.Sub64p(led.totalSupply, amount)
	newBalance := overflow.Sub64p(currentBalance, amount)

	if newBalance == 0 {
		led.balances.Remove(string(addr))
	} else {
		led.balances.Set(string(addr), newBalance)
	}

	led.token.emit(
		TransferEvent,
		"from", string(addr),
		"to", "",
		"value", strconv.Itoa(int(amount)),
	)

	return nil
}

// hasAddr checks if the specified address is a known account in the ledger.
func (led PrivateLedger) hasAddr(addr address) bool {
	return led.balances.Has(addr.String())
}

// balanceOf returns the balance of the specified address.
func (led PrivateLedger) balanceOf(addr address) int64 {
	balance := led.balances.Get(addr.String())
	if balance == nil {
		return 0
	}
	return balance.(int64)
}

// allowance returns the allowance of the specified owner and spender.
func (led PrivateLedger) allowance(owner, spender address) int64 {
	allowance := led.allowances.Get(allowanceKey(owner, spender))
	if allowance == nil {
		return 0
	}
	return allowance.(int64)
}

// allowanceKey returns the key for the allowance of the specified owner and spender.
func allowanceKey(owner, spender address) string {
	return owner.String() + ":" + spender.String()
}
