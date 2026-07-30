package client

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gnolang/gno/tm2/pkg/commands"
	"github.com/gnolang/gno/tm2/pkg/crypto/keys"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// realValidatorKey is a sample validator key file, in the same amino JSON
// format produced by gnoland for priv_validator_key.json.
const realValidatorKey = `{
  "priv_key": {
    "@type": "/tm.PrivKeyEd25519",
    "value": "YEEU3/PF7tbzY5YswtliXeqmf9eOXQ9h4I7ZI4fit4hkEqqiE3GKtcyfoVh3GOEP2gyygya6Kjw01uyB74A6iA=="
  },
  "pub_key": {
    "@type": "/tm.PubKeyEd25519",
    "value": "ZBKqohNxirXMn6FYdxjhD9oMsoMmuio8NNbsge+AOog="
  },
  "address": "g10upt8gsd2y87q7znd227wqy6em6z46mapq5exj"
}`

const realValidatorAddress = "g10upt8gsd2y87q7znd227wqy6em6z46mapq5exj"

// writeValidatorKey writes the given key file content to a temp file.
func writeValidatorKey(t *testing.T, content string) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "priv_validator_key.json")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))

	return path
}

func TestAdd_Validator(t *testing.T) {
	t.Parallel()

	t.Run("valid validator key addition", func(t *testing.T) {
		t.Parallel()

		var (
			kbHome      = t.TempDir()
			baseOptions = BaseOptions{
				InsecurePasswordStdin: true,
				Home:                  kbHome,
			}

			keyName = "validator-key"
			keyPath = writeValidatorKey(t, realValidatorKey)
		)

		ctx, cancelFn := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelFn()

		io := commands.NewTestIO()
		io.SetIn(strings.NewReader("test1234\ntest1234\n"))

		cmd := NewRootCmdWithBaseConfig(io, baseOptions)

		args := []string{
			"add",
			"validator",
			"--insecure-password-stdin",
			"--home", kbHome,
			"--key-path", keyPath,
			keyName,
		}

		require.NoError(t, cmd.ParseAndRun(ctx, args))

		// Check the keybase
		kb, err := keys.NewKeyBaseFromDir(kbHome)
		require.NoError(t, err)

		info, err := kb.GetByName(keyName)
		require.NoError(t, err)
		require.NotNil(t, info)

		// The derived address must match the one in the key file
		assert.Equal(t, realValidatorAddress, info.GetAddress().String())

		// The key must be a local (signing-capable) key, not offline
		assert.Equal(t, keys.TypeLocal, info.GetType())
	})

	t.Run("imported key can sign", func(t *testing.T) {
		t.Parallel()

		var (
			kbHome      = t.TempDir()
			baseOptions = BaseOptions{
				InsecurePasswordStdin: true,
				Home:                  kbHome,
			}

			keyName    = "validator-key"
			passphrase = "test1234"
			keyPath    = writeValidatorKey(t, realValidatorKey)
		)

		ctx, cancelFn := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelFn()

		io := commands.NewTestIO()
		io.SetIn(strings.NewReader(passphrase + "\n" + passphrase + "\n"))

		cmd := NewRootCmdWithBaseConfig(io, baseOptions)

		require.NoError(t, cmd.ParseAndRun(ctx, []string{
			"add", "validator",
			"--insecure-password-stdin",
			"--home", kbHome,
			"--key-path", keyPath,
			keyName,
		}))

		kb, err := keys.NewKeyBaseFromDir(kbHome)
		require.NoError(t, err)

		// Sign an arbitrary payload with the imported key
		payload := []byte("sign me")

		sig, pub, err := kb.Sign(keyName, passphrase, payload)
		require.NoError(t, err)

		// The signature must verify against the key file's public key
		assert.True(t, pub.VerifyBytes(payload, sig))
		assert.Equal(t, realValidatorAddress, pub.Address().String())
	})

	t.Run("missing key path", func(t *testing.T) {
		t.Parallel()

		kbHome := t.TempDir()
		baseOptions := BaseOptions{
			InsecurePasswordStdin: true,
			Home:                  kbHome,
		}

		ctx, cancelFn := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelFn()

		io := commands.NewTestIO()
		cmd := NewRootCmdWithBaseConfig(io, baseOptions)

		err := cmd.ParseAndRun(ctx, []string{
			"add", "validator",
			"--insecure-password-stdin",
			"--home", kbHome,
			"key-name",
		})

		assert.ErrorIs(t, err, errMissingValidatorKeyPath)
	})

	t.Run("tampered key file is rejected", func(t *testing.T) {
		t.Parallel()

		var (
			kbHome      = t.TempDir()
			baseOptions = BaseOptions{
				InsecurePasswordStdin: true,
				Home:                  kbHome,
			}

			// Address does not match the public key
			tampered = strings.Replace(
				realValidatorKey,
				realValidatorAddress,
				"g1qpymzwx4l4cy6cerdyajp9ksvjsf20rk5y9rtt",
				1,
			)
			keyPath = writeValidatorKey(t, tampered)
		)

		ctx, cancelFn := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelFn()

		io := commands.NewTestIO()
		cmd := NewRootCmdWithBaseConfig(io, baseOptions)

		err := cmd.ParseAndRun(ctx, []string{
			"add", "validator",
			"--insecure-password-stdin",
			"--home", kbHome,
			"--key-path", keyPath,
			"key-name",
		})

		require.Error(t, err)
		assert.Contains(t, err.Error(), "unable to load validator key file")
	})

	t.Run("force overwrites an existing key", func(t *testing.T) {
		t.Parallel()

		var (
			kbHome      = t.TempDir()
			baseOptions = BaseOptions{
				InsecurePasswordStdin: true,
				Home:                  kbHome,
			}

			keyName = "validator-key"
			keyPath = writeValidatorKey(t, realValidatorKey)
		)

		ctx, cancelFn := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelFn()

		io := commands.NewTestIO()
		io.SetIn(strings.NewReader(strings.Repeat("test1234\n", 4)))

		cmd := NewRootCmdWithBaseConfig(io, baseOptions)

		args := []string{
			"add", "validator",
			"--insecure-password-stdin",
			"--home", kbHome,
			"--key-path", keyPath,
			"--force",
			keyName,
		}

		// Import twice; the second one must not fail on the no-overwrite guard
		require.NoError(t, cmd.ParseAndRun(ctx, args))

		cmd = NewRootCmdWithBaseConfig(io, baseOptions)
		require.NoError(t, cmd.ParseAndRun(ctx, args))

		kb, err := keys.NewKeyBaseFromDir(kbHome)
		require.NoError(t, err)

		info, err := kb.GetByName(keyName)
		require.NoError(t, err)
		assert.Equal(t, realValidatorAddress, info.GetAddress().String())
	})
}
