package client

import (
	"context"
	"errors"
	"flag"
	"fmt"

	"github.com/gnolang/gno/tm2/pkg/bft/privval/signer/local"
	"github.com/gnolang/gno/tm2/pkg/commands"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/crypto/keys"
)

var errMissingValidatorKeyPath = errors.New("validator key path not provided")

type AddValidatorCfg struct {
	RootCfg *AddCfg

	KeyPath string
}

// NewAddValidatorCmd creates a gnokey add validator command
func NewAddValidatorCmd(rootCfg *AddCfg, io commands.IO) *commands.Command {
	cfg := &AddValidatorCfg{
		RootCfg: rootCfg,
	}

	return commands.NewCommand(
		commands.Metadata{
			Name:       "validator",
			ShortUsage: "add validator [flags] <key-name>",
			ShortHelp:  "adds a validator private key file to the keybase",
			LongHelp: "Imports the private key from a validator key file " +
				"(priv_validator_key.json) into the keybase, so it can be used for signing.",
		},
		cfg,
		func(_ context.Context, args []string) error {
			return execAddValidator(cfg, args, io)
		},
	)
}

func (c *AddValidatorCfg) RegisterFlags(fs *flag.FlagSet) {
	fs.StringVar(
		&c.KeyPath,
		"key-path",
		"",
		"path to the validator key file (priv_validator_key.json)",
	)
}

func execAddValidator(cfg *AddValidatorCfg, args []string, io commands.IO) error {
	// Validate a key name was provided
	if len(args) != 1 {
		return flag.ErrHelp
	}

	if cfg.KeyPath == "" {
		return errMissingValidatorKeyPath
	}

	name := args[0]

	// Read the keybase from the home directory
	kb, err := keys.NewKeyBaseFromDir(cfg.RootCfg.RootCfg.Home)
	if err != nil {
		return fmt.Errorf("unable to read keybase, %w", err)
	}

	// Load the validator key file. This validates that the public key and
	// address in the file actually match the private key.
	fileKey, err := local.LoadFileKey(cfg.KeyPath)
	if err != nil {
		return fmt.Errorf("unable to load validator key file, %w", err)
	}

	newAddress := fileKey.PrivKey.PubKey().Address()

	// If not forcing, check for collisions with existing keys
	if !cfg.RootCfg.Force {
		// Handle address / name collision if any
		handled, err := handleCollision(kb, name, newAddress, keys.TypeLocal, io)
		if err != nil {
			return err
		}
		// If a collision was found and handled, we can skip saving the new key
		if handled {
			return nil
		}
	}

	// Ask for passphrase only when proceeding with key creation
	pw, err := promptPassphrase(io, cfg.RootCfg.RootCfg.InsecurePasswordStdin)
	if err != nil {
		return err
	}

	// ImportPrivKey refuses to overwrite, so drop any existing key that the
	// user already agreed to replace (either via --force or the override prompt)
	if err := deleteIfExists(kb, name, newAddress); err != nil {
		return err
	}

	// Import the private key
	if err := kb.ImportPrivKey(name, fileKey.PrivKey, pw); err != nil {
		return fmt.Errorf("unable to import the validator private key, %w", err)
	}

	io.Printfln("Key %q saved to disk.\n", name)

	return nil
}

// deleteIfExists removes any key colliding with the given name or address,
// so that a subsequent import does not fail on the no-overwrite guard.
func deleteIfExists(kb keys.Keybase, name string, address crypto.Address) error {
	for _, key := range []string{name, address.String()} {
		info, err := kb.GetByNameOrAddress(key)
		if err != nil {
			// Nothing to delete
			continue
		}

		if err := kb.Delete(info.GetName(), "", true); err != nil {
			return fmt.Errorf("unable to delete the existing key %q, %w", info.GetName(), err)
		}
	}

	return nil
}
