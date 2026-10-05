package signing

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Supported document payload types per docs/specs/03-security-and-trust.md
const (
	PayloadTypePlan        = "application/vnd.shepherd.plan.v1+json"
	PayloadTypeTarget      = "application/vnd.shepherd.target.v1+json"
	PayloadTypeInstruction = "application/vnd.shepherd.instruction.v1+json"
	PayloadTypePeerList    = "application/vnd.shepherd.peer-list.v1+json"
	PayloadTypeKeySet      = "application/vnd.shepherd.key-set.v1+json"
)

// AllowedPayloadTypes names the authorized Shepherd document types.
var AllowedPayloadTypes = map[string]bool{
	PayloadTypePlan:        true,
	PayloadTypeTarget:      true,
	PayloadTypeInstruction: true,
	PayloadTypePeerList:    true,
	PayloadTypeKeySet:      true,
}

var (
	ErrInvalidEnvelope        = errors.New("signing: invalid envelope structure")
	ErrUnexpectedPayloadType  = errors.New("signing: unexpected payload type")
	ErrUnsupportedPayloadType = errors.New("signing: unsupported payload type")
	ErrNoSignatures           = errors.New("signing: envelope contains no signatures")
	ErrUnknownKeyID           = errors.New("signing: signature key id not in trusted key set")
	ErrInvalidSignature       = errors.New("signing: cryptographic signature verification failed")
	ErrInvalidKey             = errors.New("signing: invalid key size or format")
)

// Signature represents a single key signature in a DSSE envelope.
type Signature struct {
	KeyID string `json:"keyid"`
	Sig   string `json:"sig"` // Base64 standard or URL-safe encoded
}

// Envelope represents a DSSE (Dead Simple Signing Envelope).
type Envelope struct {
	PayloadType string      `json:"payloadType"`
	Payload     string      `json:"payload"` // Base64 standard or URL-safe encoded
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

// Add registers a trusted public key for keyID after verifying its length.
func (ks *KeySet) Add(keyID string, pub ed25519.PublicKey) error {
	if len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("%w: public key %q must be %d bytes, got %d", ErrInvalidKey, keyID, ed25519.PublicKeySize, len(pub))
	}
	ks.Keys[keyID] = pub
	return nil
}

// Get retrieves the public key for keyID.
func (ks *KeySet) Get(keyID string) (ed25519.PublicKey, bool) {
	k, ok := ks.Keys[keyID]
	return k, ok
}

// CanonicalizeJSON converts raw JSON bytes into RFC 8785 canonical form (sorted keys, no extraneous whitespace).
func CanonicalizeJSON(payload []byte) ([]byte, error) {
	var v any
	if err := json.Unmarshal(payload, &v); err != nil {
		return nil, fmt.Errorf("signing: failed to unmarshal json for canonicalization: %w", err)
	}
	return json.Marshal(v)
}

// decodeBase64 decodes standard or URL-safe base64, with or without padding.
func decodeBase64(s string) ([]byte, error) {
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.URLEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.RawURLEncoding.DecodeString(s)
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
// If payloadType is a JSON document (+json or application/json), it is canonicalized (RFC 8785).
func Sign(payloadType string, payload []byte, signer Signer) (*Envelope, error) {
	if signer == nil {
		return nil, errors.New("signing: signer cannot be nil")
	}
	if payloadType == "" {
		return nil, errors.New("signing: payloadType cannot be empty")
	}

	finalPayload := payload
	if strings.HasSuffix(payloadType, "+json") || payloadType == "application/json" {
		canonical, err := CanonicalizeJSON(payload)
		if err != nil {
			return nil, err
		}
		finalPayload = canonical
	}

	pae := PAE(payloadType, finalPayload)
	sigBytes, err := signer.Sign(pae)
	if err != nil {
		return nil, fmt.Errorf("signing: failed to sign PAE: %w", err)
	}

	env := &Envelope{
		PayloadType: payloadType,
		Payload:     base64.StdEncoding.EncodeToString(finalPayload),
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
// expectedType must be non-empty and in the supported document type allow-list.
// Base64 payloads and signatures in either standard or URL-safe form are accepted.
func Verify(env *Envelope, keys *KeySet, expectedType string) ([]byte, string, error) {
	if env == nil {
		return nil, "", ErrInvalidEnvelope
	}
	if expectedType == "" {
		return nil, "", errors.New("signing: expectedType is required")
	}
	if !AllowedPayloadTypes[expectedType] {
		return nil, "", fmt.Errorf("%w: %q", ErrUnsupportedPayloadType, expectedType)
	}
	if env.PayloadType != expectedType {
		return nil, "", fmt.Errorf("%w: got %q, expected %q", ErrUnexpectedPayloadType, env.PayloadType, expectedType)
	}
	if len(env.Signatures) == 0 {
		return nil, "", ErrNoSignatures
	}

	payloadBytes, err := decodeBase64(env.Payload)
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

		if len(pubKey) != ed25519.PublicKeySize {
			return nil, "", fmt.Errorf("%w: key %q has invalid size %d", ErrInvalidKey, sig.KeyID, len(pubKey))
		}

		sigBytes, err := decodeBase64(sig.Sig)
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
