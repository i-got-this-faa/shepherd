package signing

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
)

var (
	ErrInvalidEnvelope       = errors.New("signing: invalid envelope structure")
	ErrUnexpectedPayloadType = errors.New("signing: unexpected payload type")
	ErrNoSignatures          = errors.New("signing: envelope contains no signatures")
	ErrUnknownKeyID          = errors.New("signing: signature key id not in trusted key set")
	ErrInvalidSignature      = errors.New("signing: cryptographic signature verification failed")
)

// Signature represents a single key signature in a DSSE envelope.
type Signature struct {
	KeyID string `json:"keyid"`
	Sig   string `json:"sig"` // Base64 standard encoded
}

// Envelope represents a DSSE (Dead Simple Signing Envelope).
type Envelope struct {
	PayloadType string      `json:"payloadType"`
	Payload     string      `json:"payload"` // Base64 standard encoded
	Signatures  []Signature `json:"signatures"`
}

// Signer abstracts signing operations for DSSE envelopes.
type Signer interface {
	KeyID() string
	Sign(data []byte) ([]byte, error)
}

// Ed25519Signer implements Signer using an ed25519.PrivateKey.
type Ed25519Signer struct {
	keyID      string
	privateKey ed25519.PrivateKey
}

// NewEd25519Signer creates an Ed25519Signer for keyID and privateKey.
func NewEd25519Signer(keyID string, priv ed25519.PrivateKey) *Ed25519Signer {
	return &Ed25519Signer{
		keyID:      keyID,
		privateKey: priv,
	}
}

func (s *Ed25519Signer) KeyID() string {
	return s.keyID
}

func (s *Ed25519Signer) Sign(data []byte) ([]byte, error) {
	if len(s.privateKey) != ed25519.PrivateKeySize {
		return nil, errors.New("signing: invalid ed25519 private key size")
	}
	return ed25519.Sign(s.privateKey, data), nil
}

// KeySet stores trusted Ed25519 public keys indexed by their key ID.
type KeySet struct {
	Keys map[string]ed25519.PublicKey `json:"keys"`
}

// NewKeySet initializes an empty KeySet.
func NewKeySet() *KeySet {
	return &KeySet{
		Keys: make(map[string]ed25519.PublicKey),
	}
}

// Add registers a trusted public key for keyID.
func (ks *KeySet) Add(keyID string, pub ed25519.PublicKey) {
	ks.Keys[keyID] = pub
}

// Get retrieves the public key for keyID.
func (ks *KeySet) Get(keyID string) (ed25519.PublicKey, bool) {
	k, ok := ks.Keys[keyID]
	return k, ok
}

// PAE computes the DSSE Pre-Authentication Encoding:
// "DSSEv1" + " " + len(type) + " " + type + " " + len(body) + " " + body
func PAE(payloadType string, payload []byte) []byte {
	prefix := fmt.Sprintf("DSSEv1 %d %s %d ", len(payloadType), payloadType, len(payload))
	out := make([]byte, 0, len(prefix)+len(payload))
	out = append(out, prefix...)
	out = append(out, payload...)
	return out
}

// Sign creates a DSSE envelope with the provided payloadType and payload.
func Sign(payloadType string, payload []byte, signer Signer) (*Envelope, error) {
	if signer == nil {
		return nil, errors.New("signing: signer cannot be nil")
	}
	if payloadType == "" {
		return nil, errors.New("signing: payloadType cannot be empty")
	}

	pae := PAE(payloadType, payload)
	sigBytes, err := signer.Sign(pae)
	if err != nil {
		return nil, fmt.Errorf("signing: failed to sign PAE: %w", err)
	}

	env := &Envelope{
		PayloadType: payloadType,
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures: []Signature{
			{
				KeyID: signer.KeyID(),
				Sig:   base64.StdEncoding.EncodeToString(sigBytes),
			},
		},
	}

	return env, nil
}

// Verify validates a DSSE envelope against the trusted KeySet and expectedType.
// Returns the decoded raw payload and the verifying key ID.
func Verify(env *Envelope, keys *KeySet, expectedType string) ([]byte, string, error) {
	if env == nil {
		return nil, "", ErrInvalidEnvelope
	}
	if expectedType != "" && env.PayloadType != expectedType {
		return nil, "", fmt.Errorf("%w: got %q, expected %q", ErrUnexpectedPayloadType, env.PayloadType, expectedType)
	}
	if len(env.Signatures) == 0 {
		return nil, "", ErrNoSignatures
	}

	payloadBytes, err := base64.StdEncoding.DecodeString(env.Payload)
	if err != nil {
		return nil, "", fmt.Errorf("%w: invalid base64 payload: %v", ErrInvalidEnvelope, err)
	}

	pae := PAE(env.PayloadType, payloadBytes)

	// Check signatures against trusted keys
	for _, sig := range env.Signatures {
		pubKey, ok := keys.Get(sig.KeyID)
		if !ok {
			continue // Try other signatures if present
		}

		sigBytes, err := base64.StdEncoding.DecodeString(sig.Sig)
		if err != nil {
			continue
		}

		if ed25519.Verify(pubKey, pae, sigBytes) {
			return payloadBytes, sig.KeyID, nil
		}
	}

	// Determine specific error if none verified
	for _, sig := range env.Signatures {
		if _, ok := keys.Get(sig.KeyID); !ok {
			return nil, "", fmt.Errorf("%w: %s", ErrUnknownKeyID, sig.KeyID)
		}
	}

	return nil, "", ErrInvalidSignature
}

// MarshalEnvelope serializes an Envelope to JSON bytes.
func MarshalEnvelope(env *Envelope) ([]byte, error) {
	return json.Marshal(env)
}

// UnmarshalEnvelope deserializes an Envelope from JSON bytes.
func UnmarshalEnvelope(data []byte) (*Envelope, error) {
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidEnvelope, err)
	}
	return &env, nil
}
