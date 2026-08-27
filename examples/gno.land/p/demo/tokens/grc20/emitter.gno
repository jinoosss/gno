package grc20

// TokenEmitter records a token's events from the package that declares it, so
// the VM stamps that package's path onto them. Implementations live in /r/.
// An implementation must write id as the event's "token" attribute itself.
type TokenEmitter interface {
	Emit(id, kind string, attrs []string)
}

// Emitter is a realm-bound handle that issues token identifiers and, optionally,
// records the events of the tokens built from them. Obtain one from the realm
// that owns the counter — typically a registry — or build one for your own realm.
//
// It carries the realm's functions, not its state: a copied Emitter drives the
// same counter, so no two calls return the same id. And emitter is unexported
// with no method reaching it, so holding an Emitter grants no ability to emit —
// an interface could not promise that, since a holder can assert the value back
// to a wider interface and recover the method.
type Emitter struct {
	packagePath string        // owning realm, captured at construction
	nextID      func() string // the owning realm's counter, advanced per call
	emitter     TokenEmitter  // the owning realm's event sink, or nil
}

// NewEmitter returns an Emitter bound to the caller's realm. rlm must be the
// caller's own captured cur, so PackagePath() is unforgeable and a registry can
// accept only the ids its own counter produced.
//
// nextID must advance state the caller owns; a degenerate one harms only its own
// realm. emitter may be nil, in which case tokens built from this Emitter emit
// under grc20's own pkg_path. Pass one only from the realm that declares it.
func NewEmitter(_ int, rlm realm, nextID func() string, emitter TokenEmitter) *Emitter {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}

	pkgPath := rlm.PkgPath()
	if pkgPath == "" {
		panic(ErrNotRealm)
	}

	if nextID == nil {
		panic(ErrNilIDFunc)
	}

	return &Emitter{packagePath: pkgPath, nextID: nextID, emitter: emitter}
}

// PackagePath returns the realm the Emitter is bound to.
func (e *Emitter) PackagePath() string { return e.packagePath }

// RecordsEvents reports whether tokens built from this Emitter emit under the
// bound realm's pkg_path rather than grc20's.
func (e *Emitter) RecordsEvents() bool { return e.emitter != nil }

// NextID advances the owning realm's counter and returns the new id.
func (e *Emitter) NextID() string {
	id := e.nextID()
	if !validID(id) {
		panic(ErrInvalidID)
	}

	return id
}

// validID reports whether id is a valid trailing segment. It shares validSymbol's
// charset because it is concatenated into Token.ID(): banning `.` `/` and
// whitespace keeps ids unambiguous for downstream parsers.
func validID(id string) bool {
	return validSlugText(id, MaxIDLen)
}
