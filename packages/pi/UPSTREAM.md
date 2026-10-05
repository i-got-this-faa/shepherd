# Pi fork provenance

Upstream: https://github.com/earendil-works/pi (formerly `badlogic/pi-mono`).

Planned pin: release tag `v1.0.3`, commit
`d78dc83d633229d12f8b79631384c4c2717c399f` (2026-10-05). License: MIT.
The retained file manifest, local patch queue, and sync procedure are in
[docs/spikes/pi-fork.md](../../docs/spikes/pi-fork.md).

No source has been imported yet; #189 performs the import. When importing,
record the exact revision, retained paths, licenses/notices, local patches,
and update procedure here. Keep the model integration
(OpenAI-compatible, Anthropic, Bedrock, Google, Vertex) and the headless agent
runtime. Exclude the interactive TUI, the coding agent and its local tools,
and subscription OAuth. Fork maintenance tooling belongs under
`tools/upstream/`, and behavior checks under `tests/pi/`.
