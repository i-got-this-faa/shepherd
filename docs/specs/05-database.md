# 05 — Database

PostgreSQL (pin a major version in week 1; 17 recommended). Migrations with
`goose` in `apps/control-plane/migrations/`, queries with `sqlc`. UUIDv7
primary keys (time-ordered) `[impl]`. All timestamps `timestamptz`.

## Tables

### Identity and audit

| Table | Key columns |
|---|---|
| `admins` | id, username (unique), password_hash, totp_secret_ref, role, disabled_at, created_at |
| `admin_sessions` | id (hash of cookie), admin_id, csrf_token_hash, created_at, last_seen_at, expires_at, ip, user_agent |
| `audit_events` | id, at, actor_type (`admin\|node\|agent\|system`), actor_id, action, target_type, target_id, config_revision, generation_id, result (`ok\|denied\|failed`), reason, request_id, details jsonb (redacted), prev_hash, hash |

### Machines

| Table | Key columns |
|---|---|
| `enrollment_tokens` | id, token_hash, label, platform_hint, group_id (initial group), max_uses, uses, expires_at, revoked_at, created_by |
| `machines` | id, hostname, platform, os_edition, os_version, status (`enrolling\|active\|offline\|removed\|assignment-conflict`), enrolled_at, removed_at, last_seen_at, last_report_at, daemon_version, auto_fix (nullable override) |
| `machine_keys` | machine_id, identity_pubkey, tailcat_node_pubkey, tailcat_addr (node's own listener addr for peers), created_at, revoked_at |
| `machine_inventory` | machine_id, collected_at, document jsonb (inventory.v1) |
| `machine_capabilities` | machine_id, capability_id, state, reason, updated_at |
| `machine_managers_detected` | machine_id, manager (`intune\|sccm\|gpo-domain\|jamf\|puppet\|...`), evidence, detected_at, resolved_at [ADM-03] |

### Assignment

| Table | Key columns |
|---|---|
| `groups` | id, name, description |
| `group_members` | group_id, machine_id |
| `profiles` | id, name, description, platforms text[], auto_fix bool default false, current_revision_id |
| `profile_assignments` | id, profile_id, subject_type (`group\|machine`), subject_id, created_by, created_at — unique(subject_type, subject_id) |

### Configuration

| Table | Key columns |
|---|---|
| `config_revisions` | id, profile_id, git_sha, parent_revision_id, source (`gui\|advanced\|agent-draft\|import`), author_type, author_id, message, created_at |
| `drafts` | id, profile_id, base_revision_id, gui_model jsonb, custom_modules jsonb (file path → content), state (`editing\|evaluating\|valid\|invalid\|approved\|superseded\|discarded`), created_by_type, created_by_id |
| `evaluations` | id, draft_id or revision_id, platform, state, started_at, finished_at, error_text, error_location jsonb, plan_preview jsonb, omitted jsonb, store_path_preview |
| `approvals` | id, revision_id, approved_by (admin only), approved_at, comment, acknowledged_destructive bool |

### Deployment

| Table | Key columns |
|---|---|
| `generations` | id, revision_id, profile_id, platform, artifact_ref (store path or plan digest), nar_hash, signed_plan_template (for Windows: compiled resources before per-machine finalization), built_at, build_log_ref |
| `deployments` | id, revision_id, approval_id, state (`pending\|rolling\|paused\|completed\|failed\|cancelled`), rollout_policy jsonb, created_at |
| `machine_targets` | machine_id (PK), generation_id, deployment_id, signed_envelope bytea, digest, apply_after, assigned_at |
| `machine_generations` | machine_id, generation_id, state (`pending\|fetching\|activating\|healthy\|unhealthy\|failed\|recovered\|superseded`), activated_at, health_at, is_last_working bool, report_id |
| `instructions` | id, machine_id, kind, payload jsonb, signed_envelope, created_at, acked_at, result |
| `maintenance_windows` | id, scope_type (`profile\|group\|machine`), scope_id, rrule or cron, duration, timezone, allow_reboot |

### Telemetry

| Table | Key columns |
|---|---|
| `heartbeats` | machine_id, at, active_generation_id, pending_reboot, transport (`direct\|derp`) — retained 7 days, or keep only latest in `machines` + sampled history |
| `reports` | id, machine_id, kind, generation_id, plan_id, trigger, started_at, finished_at, received_at, health_status, document jsonb |
| `report_results` | report_id, resource_key, status, evidence, error_code, observed jsonb, desired jsonb |
| `drift_findings` | id, machine_id, generation_id, resource_key, first_seen_at, last_seen_at, resolved_at, resolution (`autofix\|manual-reapply\|config-change\|external`) |

### Agents

| Table | Key columns |
|---|---|
| `agent_sessions` | id, kind (`central\|node`), machine_id null, started_by, purpose, started_at, ended_at, model, status |
| `agent_messages` | session_id, seq, role, content (redacted), tool_name, created_at |
| `agent_tool_calls` | id, session_id, tool, input jsonb, output_digest, authorized bool, denied_reason |

### MDM

| Table | Key columns |
|---|---|
| `mdm_devices` | machine_id, udid, enrollment_id, push_magic_ref, topic, enrolled_at, last_checkin_at |
| `mdm_commands` | id, machine_id, request_type, payload_ref, status, queued_at, completed_at, error |

## Invariants enforced in the database

- `approvals.approved_by` references `admins` (agents cannot appear) [AGT-05].
- Unique active direct assignment per machine; unique per group.
- `machine_generations` has at most one `is_last_working = true` per machine
  (partial unique index) [DEP-05].
- `audit_events` has no UPDATE/DELETE grants for the application role.

## Retention `[impl]`

Reports: keep all apply/recovery reports; drift reports 30 days except those
that opened or closed a finding. Heartbeats: 7 days. Agent messages: 90 days.
Audit: forever in V1.

## Acceptance

- Migrations apply up and down on an empty database in CI.
- sqlc compiles; no hand-written SQL outside `queries/`.
- Invariant tests: inserting a second last-working row fails; deleting an
  audit row fails for the app role.
