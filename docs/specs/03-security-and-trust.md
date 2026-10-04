# 03 — Security and trust

## Key inventory

| Key | Algorithm | Holder | Purpose | Rotation |
|---|---|---|---|---|
| Plan signing key | Ed25519 | Control plane signer (file with 0600 or KMS-like local secret store; never in DB plaintext) | Signs DSSE envelopes for plans and targets [DEP-01] | Rotatable; nodes trust a key set with `kid`s ([Rotation](#rotation)) |
| Nix store signing key | Ed25519 (Nix format `name:base64`) | Build worker | Signs NAR info published to Attic | Rotatable; trusted-public-keys distributed in plan/bootstrap |
| Control plane Tailcat key + PSK | Curve25519 node key + WireGuard PSK | Control plane | Mesh identity; its `TailcatAddr` is pinned in the enrollment bundle | Rotate with dual-address overlap |
| Node Tailcat key | Curve25519 | Each node (OS-protected store) | Node mesh identity; admitted by control plane `AllowClient` | Re-key instruction |
| Node identity key | Ed25519 | Each node | Signs reports and requests; bound to machine id at enrollment [ADM-04] | Re-key instruction |
| Enrollment token | 256-bit random, stored as Argon2id hash | Admin → installer media | One-time or limited-use bootstrap [ADM-01] | Expiry (default 7 days), max uses |
| Admin credentials | Argon2id password hash + TOTP (optional in V1, required before non-demo) | Admins | Console login [ADM-04] | — |
| Attic tokens | JWT (Attic native) | Control plane issues per node (pull) and build worker (push) | Cache access | Short-lived pull tokens refreshed via heartbeat |
| FBS credentials | SigV4 access key / Bearer | Attic only | Object storage | Manual rotation documented |
| APNs push cert, MDM identity | X.509 | NanoMDM | Apple MDM | Yearly; tracked in ops runbook |
| Model API key | Opaque | Central agent config | LLM access | Out of scope for Shepherd rotation |

Rules:

1. No private key or secret is stored in the git config repo, in PostgreSQL in
   plaintext, in plans, reports, journals, or logs [Deployment dependencies].
2. The browser and the agents never receive any key in this table [AGT-06].
3. Server secrets load from a directory (`/var/lib/shepherd/secrets/`) with a
   documented file layout; on NixOS deployments via agenix/sops-nix compatible paths.
4. Node secrets: Windows → DPAPI machine scope + file ACL SYSTEM-only under
   `C:\ProgramData\Shepherd\state\`; Linux → `/var/lib/shepherd/` 0700 root;
   macOS → System keychain or 0600 root file.

## Signed envelope format `[impl]`

Use **DSSE** (Dead Simple Signing Envelope):

```json
{ "payloadType": "application/vnd.shepherd.plan.v1+json",
  "payload": "<base64 of canonical JSON>",
  "signatures": [ { "keyid": "plan-2026-10", "sig": "<base64 ed25519>" } ] }
```

- PAE (pre-authentication encoding) per DSSE spec prevents type confusion.
- Payload types: `plan.v1`, `target.v1`, `instruction.v1`, `peer-list.v1`,
  `key-set.v1`.
- Library: `internal/signing` (Go) with `Sign(payloadType, payload, signer)`
  and `Verify(envelope, trustedKeys, expectedType) (payload, keyid, error)`.
  TS verification helper in contracts for the console (display only).

Verification on the node MUST check, in order: envelope parse → payload type →
signature against trusted key set → payload schema → `machineId` equals self →
`expiresAt` in the future → `generationId` is the current or newer target per
heartbeat (anti-rollback: never accept a plan whose `createdAt` is older than
the last accepted plan unless the instruction is `Recover` signed for that
generation) [DEP-01, DEP-05].

## Rotation

- The node stores a **trusted key set** document (`key-set.v1`) signed by the
  current key. A rotation publishes a new key set signed by the *old* key that
  includes both keys; after all active nodes ack, the server switches signing
  to the new key and later publishes a set without the old key.
- Rotation procedure is exposed as `shepherdctl keys rotate plan` and as a
  console admin action in week 6 [ADM-04].

## Revocation

- Removing a machine ([ADM-02]) revokes: machine identity, Tailcat admission
  (`DisconnectClient` + removal from allow set), Attic pull token, and pending
  targets. A revoked identity's heartbeat returns `PERMISSION_DENIED` with
  `Unenroll` semantics; no new plan is signed for it [DEM-08].
- Enrollment tokens can be revoked before use.

## Administrator authentication

- Local admin accounts in PostgreSQL (`admins`), Argon2id(m=64MiB,t=3,p=1).
- Session: random 256-bit id in an `HttpOnly; Secure; SameSite=Strict` cookie,
  server-side session row with idle (30 min) and absolute (12 h) expiry.
- CSRF: double-submit token header on all mutating Connect calls.
- First-run bootstrap: `shepherd admin create` CLI on the server host only.
- Optional TOTP in week 6. OIDC is post-V1.
- Single role "administrator" in V1 [Purpose and users]; authorization code
  still checks a `role` column so later roles do not require refactors.

## Approval authority [AGT-04, AGT-05]

- Every deployment of a new configuration identity requires an `approvals`
  row created by an authenticated admin through the console API. Agents have
  no RPC that creates approvals; the RPC handler rejects any caller whose
  principal type is `agent`.
- The auto-fix toggle (per profile or machine) authorizes only reapplication of
  the **already approved** current generation on that node. The server
  enforces this by only allowing `Reapply`/repair instructions whose
  `generationId` equals the node's approved target.
- Node agent repair requests go through the daemon to `RequestRepair`; the
  server checks auto-fix and returns a signed `Reapply` instruction or denies.

## Audit log [ADM-05]

Append-only `audit_events` table (actor type/id, action, target type/id,
configuration identity, result, failure reason, request id, ip, timestamp).
Hash-chained (`prev_hash`, `hash = sha256(prev_hash || canonical(row))`) so
tampering is detectable `[impl]`. Never stores secrets; values are redacted by
a field allow-list.

## Threat checklist for week 6 review

- Plan replay/rollback, expired plans, plan for another machine.
- Stolen enrollment token reuse; token on lost USB.
- Compromised node attempting to fetch other nodes' plans or peer data.
- Peer serving tampered chunks (must fail NAR hash verification).
- Agent prompt injection via machine-reported strings (logs, package names) —
  agents have no mutation tools beyond drafts/repair requests.
- Console XSS via reported strings (React escaping + CSP).
- SSRF via custom Nix fetchers in build sandbox (build worker network policy).
- DERP relay sees only encrypted WireGuard packets.

## Acceptance

- Unit tests: DSSE sign/verify, wrong type, wrong key, tampered payload,
  expired plan, wrong machine id, rollback attempt.
- Integration: node rejects a plan signed by an unknown key and reports
  `plan-rejected` with reason; console shows it.
- Key rotation exercised end to end on two VMs without re-enrollment.
- Removed machine cannot fetch a target (DEM-08).
