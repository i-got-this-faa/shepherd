# 08 — Build and artifacts

## Build worker (`shepherd-builder`)

A Go daemon that claims jobs from the control plane's PostgreSQL job queue
(or via a Connect `ClaimJob` RPC if the worker is remote `[impl: choose in issue]`)
and runs Nix in an isolated environment.

Job kinds:

| Kind | Input | Output |
|---|---|---|
| `evaluate` | repo sha/branch, host ids, platforms | JSON outputs, drv paths, errors with locations |
| `build` | approved sha, host ids | store paths, NAR hashes, closure size, build log ref |
| `publish` | store paths | pushed to Attic, signatures verified as present |
| `compile-windows` | evaluated resources + host facts | plan template (may run in CP instead; decided in issue) |

Isolation [Architecture: build worker isolation]:

- Runs as an unprivileged `shepherd-builder` user with a dedicated Nix daemon
  configuration: `sandbox = true`, `restrict-eval = true` for evaluation of
  custom modules, `allowed-uris` limited to the pinned inputs, no access to
  control plane secrets except the Nix signing key file (read-only) and
  Attic push token.
- Checks out the config repo at an exact sha into a temp dir; deletes after.
- Hard timeouts and output size limits; logs stored in FBS (`build-logs/`
  bucket) and referenced from `generations.build_log_ref`.

Platform placement: Linux builders build NixOS closures (x86_64-linux,
aarch64-linux via native or remote builder). Darwin closures need a macOS
builder (a Mac running `shepherd-builder` registered with `platforms=darwin`)
— the job queue routes by platform [Deployment dependencies].

## Artifact identity

`artifact_ref` = Nix store path (content-addressed by derivation) plus the
NAR hash of the closure root. A generation is identified by `generation_id`
(UUID) bound to (revision sha, profile, platform, machine, artifact_ref).
The signed plan carries all of these so nodes can verify they received what
was approved [DEP-01].

## Signing

- Store paths are signed with the Nix signing key at build (`nix store sign`)
  before publication; Attic also signs with its own cache key — nodes trust
  **Attic's cache public key** for substitution and Shepherd verifies that the
  closure root in the plan matches what was fetched.
- The plan envelope (DSSE) is signed by the control plane signer, never by
  the build worker.

## Attic

- Deploy `atticd` (pinned revision) under `infra/storage/attic/` with a
  `server.toml` using the S3 storage backend pointed at FBS:
  `endpoint = "http://fbs:9000"`, `region = "us-east-1"`, bucket `attic`,
  path-style addressing, credentials from env.
- One cache `shepherd` (private). Tokens: build worker push token (scoped to
  `shepherd`, push+pull), node pull tokens minted by the control plane with
  short expiry (Attic JWT signed with the Attic token secret held by the
  control plane) `[impl]`.
- Chunking/dedup enabled (Attic default). Garbage collection: retain all
  closures referenced by any `machine_generations` row with state in
  {healthy, is_last_working} plus the last 10 generations per profile/platform.

## FBS

- Build pinned `fbs-core` revision from `github.com/i-got-this-faa/fbs-core`
  (GPL-3.0, separate service — no linking into Shepherd binaries) as a
  container image or Nix package; record the revision/digest in
  `infra/storage/fbs/UPSTREAM.md`.
- Bootstrap via loopback `POST /api/setup/bootstrap`; store the admin token
  and SigV4 keys in the server secrets dir; create a dedicated SigV4 user for
  Attic with access to bucket `attic` only, and one for build logs.
- Persistent volume for data and SQLite metadata; backup procedure documented
  in ops runbook (SQLite `.backup` + data dir rsync while paused) since FBS is
  single-node with no HA.

## Attic + FBS compatibility suite [Dependency management]

`tests/storage/attic-fbs/` — runs in `integration.yml` with docker-compose:

1. SigV4 authenticated PUT/GET/HEAD/DELETE against custom endpoint, path-style.
2. Multipart create/upload/complete and abort; ListParts.
3. `attic push` of a ~200 MB closure (forces multipart), `attic` pull on a
   clean client via substituter, NAR hash match.
4. Restart FBS and Attic; re-pull succeeds (persistence).
5. Signed read URLs if Attic is configured to redirect to storage (decide:
   keep Attic proxying in V1 so nodes never need direct FBS reachability) `[impl]`.
6. Failure handling: FBS down → Attic push fails cleanly, build job marked
   failed with reason, no generation created.

## Acceptance

- Approving a NixOS draft produces a generation whose store path is
  substitutable from Attic by a fresh NixOS VM.
- Compatibility suite green in CI.
- Build of a custom module that tries network access fails in the sandbox.
