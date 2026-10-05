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
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "unordered keys with whitespace",
			input:    "{\n  \"z\": 1,\n  \"a\": 2\n}",
			expected: `{"a":2,"z":1}`,
		},
		{
			name: "RFC 8785 preserves HTML chars without escaping",
			// Go default json.Marshal escapes < as \u003c, > as \u003e, and & as \u0026.
			// RFC 8785 requires raw <, >, and & characters.
			input:    `{"html": "<script>alert('a & b > c');</script>"}`,
			expected: `{"html":"<script>alert('a & b > c');</script>"}`,
		},
		{
			name: "RFC 8785 preserves raw UTF-8 characters",
			// UTF-8 characters must not be escaped into \uXXXX.
			input:    `{"cafe": "Caf\u00e9", "greeting": "\u65e5\u672c\u8a9e"}`,
			expected: `{"cafe":"Café","greeting":"日本語"}`,
		},
		{
			name: "RFC 8785 UTF-16 code unit key sorting",
			// In UTF-16 code units, U+0041 ('A') < U+0061 ('a') < U+00E9 ('é') < U+1F600 (surrogate 0xD83D) < U+FFFD (0xFFFD)
			input:    `{"a": 1, "A": 2, "é": 3, "1": 4}`,
			expected: `{"1":4,"A":2,"a":1,"é":3}`,
		},
		{
			name: "RFC 8785 number formatting",
			// Negative zero becomes 0; integers have no decimals; exponents follow ES6.
			input:    `{"zero": -0, "float": 12.3400, "large": 1e2, "small": 0.0001}`,
			expected: `{"float":12.34,"large":100,"small":0.0001,"zero":0}`,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			canonical, err := CanonicalizeJSON([]byte(tc.input))
			if err != nil {
				t.Fatalf("failed to canonicalize %s: %v", tc.name, err)
			}
			if string(canonical) != tc.expected {
				t.Errorf("[%s]\nexpected: %s\ngot:      %s", tc.name, tc.expected, string(canonical))
			}
		})
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

func TestSignAndVerifyRFC8785Conformance(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("failed to generate key: %v", err)
	}

	keyID := "plan-rfc8785"
	signer := NewEd25519Signer(keyID, priv)
	keys := NewKeySet()
	_ = keys.Add(keyID, pub)

	// Uncanonical payload containing HTML characters (<, >) and raw UTF-8 (Café)
	rawPayload := []byte("{\n  \"command\": \"powershell -Command \\\"$x < 10 && $y > 20\\\"\",\n  \"location\": \"Caf\\u00e9\"\n}")
	expectedCanonical := `{"command":"powershell -Command \"$x < 10 && $y > 20\"","location":"Café"}`

	env, err := Sign(PayloadTypePlan, rawPayload, signer)
	if err != nil {
		t.Fatalf("failed to sign RFC 8785 payload: %v", err)
	}

	decodedPayload, err := base64.StdEncoding.DecodeString(env.Payload)
	if err != nil {
		t.Fatalf("failed to decode envelope payload: %v", err)
	}

	if string(decodedPayload) != expectedCanonical {
		t.Fatalf("envelope payload is not RFC 8785 canonical:\nexpected: %s\ngot:      %s", expectedCanonical, string(decodedPayload))
	}

	verified, kid, err := Verify(env, keys, PayloadTypePlan)
	if err != nil {
		t.Fatalf("failed to verify RFC 8785 envelope: %v", err)
	}
	if kid != keyID {
		t.Fatalf("expected kid %s, got %s", keyID, kid)
	}
	if !bytes.Equal(verified, []byte(expectedCanonical)) {
		t.Fatalf("expected verified payload %q, got %q", expectedCanonical, string(verified))
	}
}

func TestCanonicalJSON_RejectNonIJSON(t *testing.T) {
	tests := []struct {
		name        string
		input       string
		wantErrText string
	}{
		{
			name:        "duplicate key in top-level object",
			input:       `{"key": 1, "key": 2}`,
			wantErrText: "duplicate object key",
		},
		{
			name:        "duplicate key in nested object",
			input:       `{"config": {"host": "a", "host": "b"}}`,
			wantErrText: "duplicate object key",
		},
		{
			name:        "lone high surrogate escape",
			input:       `{"name": "test\uD800alone"}`,
			wantErrText: "lone high surrogate escape",
		},
		{
			name:        "lone low surrogate escape",
			input:       `{"name": "test\uDC00alone"}`,
			wantErrText: "lone low surrogate escape",
		},
		{
			name:        "high surrogate followed by non-surrogate escape",
			input:       `{"name": "test\uD800\u0041"}`,
			wantErrText: "not followed by low surrogate",
		},
		{
			name:        "truncated unicode escape",
			input:       `{"name": "test\uD80"}`,
			wantErrText: "truncated unicode escape",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := CanonicalizeJSON([]byte(tc.input))
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.wantErrText)
			}
			if !bytes.Contains([]byte(err.Error()), []byte(tc.wantErrText)) {
				t.Fatalf("expected error containing %q, got %v", tc.wantErrText, err)
			}
		})
	}
}

func TestCanonicalJSON_AcceptValidSurrogatePair(t *testing.T) {
	// Valid surrogate pair \uD83D\uDE00 (grinning face 😀)
	input := `{"emoji": "\uD83D\uDE00"}`
	canonical, err := CanonicalizeJSON([]byte(input))
	if err != nil {
		t.Fatalf("expected valid surrogate pair to succeed, got %v", err)
	}
	expected := `{"emoji":"😀"}`
	if string(canonical) != expected {
		t.Fatalf("expected %q, got %q", expected, string(canonical))
	}
}

func TestSign_RejectNonIJSON(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer := NewEd25519Signer("test-key", priv)

	// Duplicate keys should fail Sign for JSON payload types
	_, err := Sign(PayloadTypePlan, []byte(`{"id": 1, "id": 2}`), signer)
	if err == nil {
		t.Fatal("expected Sign to reject payload with duplicate keys")
	}

	// Lone surrogate should fail Sign for JSON payload types
	_, err = Sign(PayloadTypePlan, []byte(`{"note": "\uD83Dinvalid"}`), signer)
	if err == nil {
		t.Fatal("expected Sign to reject payload with lone surrogate escape")
	}
}


