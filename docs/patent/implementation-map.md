# Patent implementation map

Source reviewed: *System and Method for IT Operational Audit and Device
Lifecycle Management*, complete specification, 31 pages, dated June 11, 2025.
The source PDF remains outside this repository.

This map is an engineering interpretation, not a legal claim analysis.

| Patent element | Specification reference | Repository owner | Current state |
|---|---|---|---|
| Performance acquisition and preprocessing | paragraphs 0056 and 0074 | control plane ingestion plus device inventory | Windows inventory exists; ingestion does not |
| Fault analysis, prediction, and health status | paragraphs 0057 and 0075 | control plane health service | not implemented |
| Health-specific agent deployment | paragraphs 0058 and 0060 | control plane task assignment | not implemented |
| Federated local training and aggregation | paragraphs 0059 and 0061 | federated coordinator plus constrained endpoint worker | not implemented |
| Agentic diagnostic workflows | paragraphs 0063 and 0064 | Pi runtime with typed read tools | architecture defined, code absent |
| Repair, upgrade, or replacement reports | paragraphs 0065 and 0066 | audit reporter | Windows execution reports exist; lifecycle report does not |
| Sustainability and longevity scoring | paragraphs 0067 and 0068 | lifecycle analytics | not implemented |
| Fleet-wide component failure analysis | paragraph 0069 | fleet analytics | not implemented |
| Hierarchical controllers | paragraph 0071 | control-plane deployment architecture | deferred until scale requires it |
| Existing asset-management integration | paragraph 0079 | control-plane adapters | not implemented |

## Fit of the current Windows agent

The existing Windows code is the deterministic execution and observation layer.
It already provides inventory, drift checks, typed resource providers, journaling,
reversal, and execution reports. Those are useful foundations, but they cover
only one part of the claimed system. The controller, health model, agent task
assignment, federated aggregation, lifecycle reporting, and sustainability
analysis are still missing.

Shepherd's presentation defines the wider deterministic foundation around this
agent: unified Flake evaluation, signed builds, Attic storage, Tailcat delivery,
platform activation, health checks, canary rings, telemetry, and rollback. The
patent capabilities should consume evidence from that foundation and propose
work through it. They do not replace it.

## Pi boundary

Pi fits central workflow reasoning, Nix drafting, and report explanation. It
does not replace the health model, federated-learning coordinator, Nix
evaluator, build system, signer, rollout controller, or endpoint providers.
Treating one general agent loop as all of those components would erase the
evidence boundaries the system needs.
