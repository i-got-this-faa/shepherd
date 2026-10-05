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
	pae := PAE(PayloadTypePlan, []byte("test-payload"))
	expected := "DSSEv1 37 application/vnd.shepherd.plan.v1+json 12 test-payload"
	if string(pae) != expected {
		t.Fatalf("expected PAE %q, got %q", expected, string(pae))
	}
}

func TestCanonicalJSON(t *testing.T) {
	// Unordered JSON with whitespace
	rawJSON := []byte("{\n  \"z\": 1,\n  \"a\": 2\n}")
	canonical, err := CanonicalizeJSON(rawJSON)
	if err != nil {
		t.Fatalf("failed to canonicalize: %v", err)
	}

	expected := `{"a":2,"z":1}`
	if string(canonical) != expected {
		t.Fatalf("expected %s, got %s", expected, string(canonical))
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
	if err := keys.Add(keyID, pub); err != nil {
		t.Fatalf("failed to add key: %v", err)
	}

	payloadType := PayloadTypePlan
	payload := []byte(`{"machineId":"win-node-1","generationId":"gen-001"}`)

	env, err := Sign(payloadType, payload, signer)
	if err != nil {
		t.Fatalf("failed to sign: %v", err)
	}

	// 1. Valid verification
	verifiedPayload, verifiedKid, err := Verify(env, keys, payloadType)
	if err != nil {
		t.Fatalf("expected verification to pass: %v", err)
	}
	// Sign canonicalizes the JSON payload (keys sorted: generationId before machineId)
	expectedCanonical := `{"generationId":"gen-001","machineId":"win-node-1"}`
	if !bytes.Equal(verifiedPayload, []byte(expectedCanonical)) {
		t.Fatalf("payload mismatch: got %s, want %s", verifiedPayload, expectedCanonical)
	}
	if verifiedKid != keyID {
		t.Fatalf("expected kid %s, got %s", keyID, verifiedKid)
	}

	// 2. Unexpected payload type (still allowed type, but mismatched)
	_, _, err = Verify(env, keys, PayloadTypeTarget)
	if !errors.Is(err, ErrUnexpectedPayloadType) {
		t.Fatalf("expected ErrUnexpectedPayloadType, got %v", err)
	}

	// 3. Unsupported payload type
	_, _, err = Verify(env, keys, "application/vnd.unknown.v1+json")
	if !errors.Is(err, ErrUnsupportedPayloadType) {
		t.Fatalf("expected ErrUnsupportedPayloadType, got %v", err)
	}

	// 4. Empty expectedType rejected
	_, _, err = Verify(env, keys, "")
	if err == nil {
		t.Fatal("expected error on empty expectedType")
	}

	// 5. Unknown key ID
	emptyKeys := NewKeySet()
	_, _, err = Verify(env, emptyKeys, payloadType)
	if !errors.Is(err, ErrUnknownKeyID) {
		t.Fatalf("expected ErrUnknownKeyID, got %v", err)
	}

	// 6. Tampered payload
	tamperedEnv := *env
	tamperedEnv.Payload = base64.StdEncoding.EncodeToString([]byte(`{"tampered":true}`))
	_, _, err = Verify(&tamperedEnv, keys, payloadType)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature for tampered payload, got %v", err)
	}

	// 7. Tampered signature
	sigTamperedEnv := *env
	sigTamperedEnv.Signatures = []Signature{{KeyID: keyID, Sig: base64.StdEncoding.EncodeToString([]byte("invalid-sig"))}}
	_, _, err = Verify(&sigTamperedEnv, keys, payloadType)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature for bad sig bytes, got %v", err)
	}

	// 8. Wrong key under same ID
	pub2, _, _ := ed25519.GenerateKey(rand.Reader)
	wrongKeys := NewKeySet()
	_ = wrongKeys.Add(keyID, pub2)
	_, _, err = Verify(env, wrongKeys, payloadType)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature for wrong key, got %v", err)
	}
}

func TestURLSafeBase64Decoding(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	keyID := "test-key"
	signer := NewEd25519Signer(keyID, priv)

	keys := NewKeySet()
	_ = keys.Add(keyID, pub)

	payloadType := PayloadTypeTarget
	payload := []byte(`{"id":"target-1"}`)

	env, err := Sign(payloadType, payload, signer)
	if err != nil {
		t.Fatalf("failed to sign: %v", err)
	}

	// Re-encode payload and sig as URL-safe without padding
	rawPayload, _ := base64.StdEncoding.DecodeString(env.Payload)
	rawSig, _ := base64.StdEncoding.DecodeString(env.Signatures[0].Sig)

	urlSafeEnv := &Envelope{
		PayloadType: env.PayloadType,
		Payload:     base64.RawURLEncoding.EncodeToString(rawPayload),
		Signatures: []Signature{
			{
				KeyID: keyID,
				Sig:   base64.RawURLEncoding.EncodeToString(rawSig),
			},
		},
	}

	verified, kid, err := Verify(urlSafeEnv, keys, payloadType)
	if err != nil {
		t.Fatalf("expected URL-safe base64 decoding to verify: %v", err)
	}
	if kid != keyID {
		t.Fatalf("expected kid %s, got %s", keyID, kid)
	}
	if !bytes.Equal(verified, rawPayload) {
		t.Fatalf("payload mismatch")
	}
}

func TestKeySetValidation(t *testing.T) {
	keys := NewKeySet()

	// Short key rejected by Add
	err := keys.Add("short", []byte("too-short"))
	if !errors.Is(err, ErrInvalidKey) {
		t.Fatalf("expected ErrInvalidKey, got %v", err)
	}

	// Key injected directly into map with invalid length does not panic during Verify
	keys.Keys["bad-len"] = []byte("short-key")
	env := &Envelope{
		PayloadType: PayloadTypePlan,
		Payload:     base64.StdEncoding.EncodeToString([]byte(`{}`)),
		Signatures: []Signature{
			{KeyID: "bad-len", Sig: base64.StdEncoding.EncodeToString(make([]byte, 64))},
		},
	}

	_, _, err = Verify(env, keys, PayloadTypePlan)
	if !errors.Is(err, ErrInvalidKey) {
		t.Fatalf("expected ErrInvalidKey without panic, got %v", err)
	}
}

func TestMultipleSignatures(t *testing.T) {
	pub1, priv1, _ := ed25519.GenerateKey(rand.Reader)
	pub2, priv2, _ := ed25519.GenerateKey(rand.Reader)

	kid1 := "key-old"
	kid2 := "key-new"

	signer1 := NewEd25519Signer(kid1, priv1)
	signer2 := NewEd25519Signer(kid2, priv2)

	payloadType := PayloadTypeKeySet
	payload := []byte(`{"keys":["key-old","key-new"]}`)

	env1, _ := Sign(payloadType, payload, signer1)
	rawPayload, _ := base64.StdEncoding.DecodeString(env1.Payload)
	pae := PAE(payloadType, rawPayload)
	sig2, _ := signer2.Sign(pae)

	env1.Signatures = append(env1.Signatures, Signature{
		KeyID: kid2,
		Sig:   base64.StdEncoding.EncodeToString(sig2),
	})

	newKeysOnly := NewKeySet()
	_ = newKeysOnly.Add(kid2, pub2)

	_, verifiedKid, err := Verify(env1, newKeysOnly, payloadType)
	if err != nil {
		t.Fatalf("expected verification with new key to pass: %v", err)
	}
	if verifiedKid != kid2 {
		t.Fatalf("expected verified kid %s, got %s", kid2, verifiedKid)
	}

	oldKeysOnly := NewKeySet()
	_ = oldKeysOnly.Add(kid1, pub1)

	_, verifiedKid, err = Verify(env1, oldKeysOnly, payloadType)
	if err != nil {
		t.Fatalf("expected verification with old key to pass: %v", err)
	}
	if verifiedKid != kid1 {
		t.Fatalf("expected verified kid %s, got %s", kid1, verifiedKid)
	}
}
