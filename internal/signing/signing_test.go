package signing

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"testing"
)

func TestPAE(t *testing.T) {
	pae := PAE("application/vnd.shepherd.plan.v1+json", []byte("test-payload"))
	expected := "DSSEv1 37 application/vnd.shepherd.plan.v1+json 12 test-payload"
	if string(pae) != expected {
		t.Fatalf("expected PAE %q, got %q", expected, string(pae))
	}
}

func TestSignAndVerify(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("failed to generate key: %v", err)
	}

	keyID := "plan-2026-10"
	signer := NewEd25519Signer(keyID, priv)

	keys := NewKeySet()
	keys.Add(keyID, pub)

	payloadType := "application/vnd.shepherd.plan.v1+json"
	payload := []byte(`{"generationId":"gen-001","machineId":"win-node-1"}`)

	env, err := Sign(payloadType, payload, signer)
	if err != nil {
		t.Fatalf("failed to sign: %v", err)
	}

	// 1. Valid verification
	verifiedPayload, verifiedKid, err := Verify(env, keys, payloadType)
	if err != nil {
		t.Fatalf("expected verification to pass: %v", err)
	}
	if !bytes.Equal(verifiedPayload, payload) {
		t.Fatalf("payload mismatch: got %s, want %s", verifiedPayload, payload)
	}
	if verifiedKid != keyID {
		t.Fatalf("expected kid %s, got %s", keyID, verifiedKid)
	}

	// 2. Unexpected payload type
	_, _, err = Verify(env, keys, "application/vnd.shepherd.target.v1+json")
	if !errors.Is(err, ErrUnexpectedPayloadType) {
		t.Fatalf("expected ErrUnexpectedPayloadType, got %v", err)
	}

	// 3. Unknown key ID
	emptyKeys := NewKeySet()
	_, _, err = Verify(env, emptyKeys, payloadType)
	if !errors.Is(err, ErrUnknownKeyID) {
		t.Fatalf("expected ErrUnknownKeyID, got %v", err)
	}

	// 4. Tampered payload
	tamperedEnv := *env
	tamperedEnv.Payload = base64.StdEncoding.EncodeToString([]byte(`{"tampered":true}`))
	_, _, err = Verify(&tamperedEnv, keys, payloadType)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature for tampered payload, got %v", err)
	}

	// 5. Tampered signature
	sigTamperedEnv := *env
	sigTamperedEnv.Signatures = []Signature{{KeyID: keyID, Sig: base64.StdEncoding.EncodeToString([]byte("invalid-sig"))}}
	_, _, err = Verify(&sigTamperedEnv, keys, payloadType)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature for bad sig bytes, got %v", err)
	}

	// 6. Wrong key (different key ID or different key under same ID)
	pub2, _, _ := ed25519.GenerateKey(rand.Reader)
	wrongKeys := NewKeySet()
	wrongKeys.Add(keyID, pub2)
	_, _, err = Verify(env, wrongKeys, payloadType)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature for wrong key, got %v", err)
	}
}

func TestMultipleSignatures(t *testing.T) {
	pub1, priv1, _ := ed25519.GenerateKey(rand.Reader)
	pub2, priv2, _ := ed25519.GenerateKey(rand.Reader)

	kid1 := "key-old"
	kid2 := "key-new"

	signer1 := NewEd25519Signer(kid1, priv1)
	signer2 := NewEd25519Signer(kid2, priv2)

	payloadType := "application/vnd.shepherd.key-set.v1+json"
	payload := []byte(`{"keys":["key-old","key-new"]}`)

	env1, _ := Sign(payloadType, payload, signer1)
	pae := PAE(payloadType, payload)
	sig2, _ := signer2.Sign(pae)

	// Dual-signed envelope (e.g. during key rotation)
	env1.Signatures = append(env1.Signatures, Signature{
		KeyID: kid2,
		Sig:   base64.StdEncoding.EncodeToString(sig2),
	})

	// KeySet with only the new key trusts the envelope through the second signature
	newKeysOnly := NewKeySet()
	newKeysOnly.Add(kid2, pub2)

	_, verifiedKid, err := Verify(env1, newKeysOnly, payloadType)
	if err != nil {
		t.Fatalf("expected verification with new key to pass: %v", err)
	}
	if verifiedKid != kid2 {
		t.Fatalf("expected verified kid %s, got %s", kid2, verifiedKid)
	}

	// KeySet with only the old key trusts the envelope through the first signature
	oldKeysOnly := NewKeySet()
	oldKeysOnly.Add(kid1, pub1)

	_, verifiedKid, err = Verify(env1, oldKeysOnly, payloadType)
	if err != nil {
		t.Fatalf("expected verification with old key to pass: %v", err)
	}
	if verifiedKid != kid1 {
		t.Fatalf("expected verified kid %s, got %s", kid1, verifiedKid)
	}
}
