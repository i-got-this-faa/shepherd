// ============================================================================
//  MIET Project Synopsis
//  Model Institute of Engineering and Technology (Autonomous), Jammu
//  Department of Computer Science and Engineering
// ============================================================================

// ----------------------------------------------------------------------------
//  USER-CONFIGURABLE PARAMETERS
// ----------------------------------------------------------------------------

#let project-title = "SHEPHERD : UNIFIED DECLARATIVE CROSS-PLATFORM FLEET MANAGEMENT SYSTEM"
#let title-instruction = none

#let degree = "BACHELOR OF TECHNOLOGY"
#let degree-preposition = "In"
#let department-short = "COMPUTER SCIENCE AND ENGINEERING"

#let candidates = (
  (name: "Radhey Kalra", roll: "2023A1R044"),
  (name: "Aabish Malik", roll: "2023A6R057"),
)

#let department-full = "Department of Computer Science and Engineering"
#let institute = "Model Institute of Engineering and Technology (Autonomous)"
#let location = "Jammu, India"
#let year = "2026"
#let logo-path = "logo.png"

#let paper-size = "a4"
#let auto-page-numbers = true
#let serif-font = "Liberation Serif"

// ----------------------------------------------------------------------------
//  DOCUMENT SETUP & STYLING
// ----------------------------------------------------------------------------

#set page(
  paper: paper-size,
  margin: (top: 1in, bottom: 1in, left: 1.5in, right: 1in),
  header: none,
  footer: context {
    let p = counter(page).get().first()
    if p > 1 {
      align(center, text(font: serif-font, size: 12pt, str(p)))
    }
  },
)

#set text(
  font: serif-font,
  size: 14pt,
  lang: "en",
)

#set par(
  justify: true,
  leading: 0.65em,
  spacing: 0.9em,
)

#set list(
  marker: [•],
  spacing: 0.7em,
  body-indent: 0.5em,
)

// Helper to query page number of a labelled section
#let get-page(target-label) = context {
  if auto-page-numbers {
    let elems = query(target-label)
    if elems.len() > 0 {
      str(elems.first().location().page())
    } else {
      ""
    }
  } else {
    ""
  }
}

// Custom heading styling
#show heading.where(level: 1): it => block(
  above: 1.3em,
  below: 0.8em,
  text(size: 14pt, weight: "bold", it.body)
)

#show heading.where(level: 2): it => block(
  above: 1.1em,
  below: 0.6em,
  text(size: 14pt, weight: "bold", it.body)
)

// ============================================================================
//  COVER / TITLE PAGE
// ============================================================================

#align(center)[
  #v(0.3cm)

  #text(size: 18pt, weight: "bold")[#project-title]

  #v(1.1cm)

  #text(size: 12pt, weight: "bold")[
    A MINI PROJECT SYNOPSIS SUBMITTED\
    IN PARTIAL FULFILLMENT OF THE REQUIREMENTS\
    FOR THE AWARD OF DEGREE OF
  ]

  #v(1.0cm)

  #text(size: 14pt, weight: "bold")[
    #degree\
    #degree-preposition\
    #department-short
  ]

  #v(1.0cm)

  #text(size: 14pt, weight: "bold")[SUBMITTED BY]

  #v(0.3cm)

  #for cand in candidates [
    #text(size: 14pt)[#cand.name #if cand.roll != "" [(Roll Number: #cand.roll)]]\
  ]

  #v(1.0cm)

  #image(logo-path, width: 12.6cm)

  #v(1.0cm)

  #text(size: 14pt, weight: "bold")[SUBMITTED TO]

  #v(0.3cm)

  #text(size: 16pt)[
    #department-full\
    #institute\
    #location\
    #year
  ]
]

#pagebreak()

// ============================================================================
//  TABLE OF CONTENTS: CONTENTS OF SYNOPSIS
// ============================================================================

#align(center)[
  #text(size: 20pt, weight: "bold")[CONTENTS OF SYNOPSIS]
]

#v(1.2cm)

#align(center)[
  #table(
    columns: (2.0cm, 1fr, 2.8cm),
    stroke: 0.5pt + black,
    inset: (x: 10pt, y: 9pt),
    align: (center + horizon, left + horizon, center + horizon),
    table.header(
      [*#text(size: 16pt)[S. No]*],
      [*#text(size: 16pt)[Topic]*],
      [*#text(size: 16pt)[Page No]*],
    ),
    [#text(size: 16pt, weight: "bold")[1.]], [*#text(size: 16pt)[Project Overview]*], text(size: 16pt)[#get-page(<sec:overview>)],
    [#text(size: 16pt, weight: "bold")[2.]], [*#text(size: 16pt)[Problem Statement]*], text(size: 16pt)[#get-page(<sec:problem>)],
    [#text(size: 16pt, weight: "bold")[3.]], [*#text(size: 16pt)[Objectives of the Project]*], text(size: 16pt)[#get-page(<sec:objectives>)],
    [#text(size: 16pt, weight: "bold")[4.]], [*#text(size: 16pt)[Proposed Solution / Methodology]*], text(size: 16pt)[#get-page(<sec:solution>)],
    [#text(size: 16pt, weight: "bold")[5.]], [*#text(size: 16pt)[Key Technologies and Tools]*], text(size: 16pt)[#get-page(<sec:technologies>)],
    [#text(size: 16pt, weight: "bold")[6.]], [*#text(size: 16pt)[V.E.T.S Justification]*], text(size: 16pt)[#get-page(<sec:vets>)],
    [#text(size: 16pt, weight: "bold")[7.]], [*#text(size: 16pt)[Expected Outcomes]*], text(size: 16pt)[#get-page(<sec:outcomes>)],
    [#text(size: 16pt, weight: "bold")[8.]], [*#text(size: 16pt)[Implementation Timeline]*], text(size: 16pt)[#get-page(<sec:timeline>)],
    [#text(size: 16pt, weight: "bold")[9.]], [*#text(size: 16pt)[References]*], text(size: 16pt)[#get-page(<sec:references>)],
  )
]

#pagebreak()

// ============================================================================
//  SECTION CONTENT
// ============================================================================

= 1. Project Overview <sec:overview>

This project develops a unified declarative fleet management system tailored for educational institutions, including universities, colleges, and schools. The system belongs to the domain of Systems Engineering, Cloud Infrastructure, and Information Security. Educational institutions operate large, heterogeneous computing fleets across computer labs, libraries, and classrooms running mixed Linux, macOS, and Windows workstations that suffer from configuration drift, student tampering, and high management overhead. The proposed solution provides a central Go server that evaluates pure Nix Flakes to generate cryptographic target states for all client nodes. Native endpoint agents enforce these immutable states, verify cryptographic binary closures, and detect unauthorized drift. The target users are campus system administrators, academic lab assistants, and institutional IT directors who require verifiable, tamper-resistant infrastructure state across distributed endpoints.

#v(0.4em)

= 2. Problem Statement <sec:problem>

Educational institutions, such as universities, colleges, and schools, operate heterogeneous computing fleets across computer laboratories, smart classrooms, and administrative offices containing Linux, macOS, and Windows machines. Current configuration management tools use imperative scripts that execute divergent commands and mutate local host state directly. These imperative updates frequently fail midway, leave lab systems in partially configured states, and produce silent configuration drift exacerbated by multi-user student access. Existing tools lack unified cryptographic verification for deployed system configurations and cannot execute atomic rollbacks when student modifications or broken updates occur. Educational institutions must deploy separate, expensive proprietary vendor agents such as SCCM, Intune, and Jamf on the same network. Operating separate management silos increases software license expenses and saturates campus network bandwidth during software updates. A clear technical gap exists for a single hermetic control plane that provides immutable state reconciliation and peer-to-peer binary distribution across all three operating systems in educational institutions.

#v(0.4em)

= 3. Objectives of the Project <sec:objectives>

The objectives of this project are:
- *Design* a unified declarative schema using Nix Flakes that hermetically specifies system configurations, packages, registry settings, and security policies for Linux, macOS, and Windows.
- *Develop* a high-performance central control plane in Go 1.23 that evaluates declarative Flake inputs, dispatches target hashes over mTLS gRPC, and logs drift events in PostgreSQL 16.
- *Implement* lightweight native reconciliation agents for Linux, macOS, and Windows that continuously compare host state against target hashes and enforce atomic rollbacks upon failure.
- *Construct* an embedded peer-to-peer distribution layer using a Tailcat userspace WireGuard mesh and FastCDC content chunking to stream signed binary cache archives across local network peers.
- *Evaluate* system performance, configuration convergence time, WAN bandwidth reduction, and automatic drift detection latency across a multi-node testbed.

#v(0.4em)

= 4. Proposed Solution / Methodology <sec:solution>

The proposed solution establishes a declarative, pull-based architecture centered on cryptographic target states. Administrators define host profiles in a single central Git repository using modular Nix Flakes. The methodology divides the architecture into three technical tiers:

#align(center)[
  #image("architecture.png", width: 95%)
]

#v(0.3em)

== 4.1 Central Control Plane
The central infrastructure hosts the `shepherd` central control service, Nix Evaluator, PostgreSQL 16 database, Attic S3 binary cache, and an embedded NanoMDM service. The Nix Evaluator compiles declarative configurations into pure build derivations. The Attic cache compresses and stores signed Nix Archives (NARs) verified with Ed25519 cryptographic keys. The `shepherd` host service broadcasts desired SHA-256 target hashes to connected endpoints through outbound-only mTLS gRPC over HTTPS port 443. For macOS endpoints, the embedded NanoMDM service transmits Apple Push Notification service (APNs) commands to configure native security profiles.

== 4.2 Native Endpoint Agents
Each target operating system executes a native, minimal reconciliation agent service (`shepherd-srv`):
- *Linux Host (NixOS)*: The `shepherd-srv` client agent mounts the root filesystem on an ephemeral `tmpfs` RAM disk while maintaining `/nix/store` in read-only mode. All unauthorized runtime mutations vanish upon system reboot, guaranteeing zero state drift.
- *macOS Host (Darwin)*: The `shepherd-srv` client agent configures system packages through APFS synthetic firmlinks into `/nix/store`. Security baselines, including FileVault volume encryption and Transparency Consent and Control (TCC) profiles, are enforced via the native Apple MDM framework.
- *Windows Host (NTFS)*: The `shepherd-srv` client agent parses desired-state JSON specifications into timestamped generation bundles under `C:\ProgramData\Shepherd\generations\<hash>\`. The agent natively compiles and applies Win32 registry hives, Local Group Policy Objects (LGPO), system services, and Winget packages without requiring UNIX emulation layers.

== 4.3 P2P Mesh Distribution and Automated Rollback
Endpoints form an encrypted peer-to-peer overlay network using a Tailcat userspace WireGuard mesh powered by gVisor `netstack`. When a new target hash is received, nodes discover local LAN peers via cryptographic discovery. Missing binary store chunks are retrieved from adjacent LAN workstations using FastCDC content chunking, reducing WAN gateway saturation by up to 90%. If an update fails health verification, the agent atomically resets the active generation pointer to generation $N-1$, executing an immediate, deterministic rollback.

#v(0.4em)

= 5. Key Technologies and Tools <sec:technologies>

The implementation utilizes the following core technologies:
- *Programming Languages*: Go 1.23 for the central control server and Windows agent runtime; Nix for hermetic configuration declarations; PowerShell and Win32 C bindings for Windows policy enforcement.
- *Communication and Protocols*: gRPC over HTTP/2 with mutual TLS (mTLS) authentication; Apple APNs for MDM command transport; WireGuard protocol for network overlay transport.
- *Networking and Relays*: Tailcat userspace network mesh with gVisor `netstack`; embedded DERP (Designated Encrypted Relay for Packets) relay on HTTPS port 443 for traversal across symmetric NAT firewalls.
- *Databases and Caches*: PostgreSQL 16 for machine inventory, target hashes, and drift audit logs; Attic binary cache backed by S3 object storage with Zstandard compression and FastCDC deduplication.
- *Operating System Subsystems*: Linux `tmpfs` and `systemd`; macOS APFS synthetic firmlinks and Apple MDM framework; Windows Registry APIs, LGPO binary format, and Winget package manager.

#v(0.4em)

= 6. V.E.T.S Justification <sec:vets>

The project conforms to the evaluation criteria established in the V.E.T.S Framework:

== V - Viability
The project is technically and operationally feasible within the allocated academic semester. The architecture builds on proven, production-grade open-source components, including Go 1.23, Nix, WireGuard, and PostgreSQL. The development team possesses strong background in systems programming, operating system internals, and distributed networks. A functional lab testbed running Linux (NixOS), macOS (Darwin), and Windows 11 virtualized environments is operational and verified.

== E - Engineering Depth
The project requires significant systems engineering depth beyond simple software interfaces:
- *Cross-Platform State Compilation*: Designing a translation engine that maps unified Nix Flake declarations to native Windows Win32 registry hives, binary LGPO files, and macOS property lists.
- *Cryptographic Verification Pipeline*: Enforcing Ed25519 digital signature validation on all binary closures prior to disk activation.
- *Userspace Network Engineering*: Integrating a zero-TUN userspace WireGuard mesh with automated NAT hole-punching and HTTPS 443 DERP fallback relaying.
- *Atomic Reversal Engine*: Engineering continuous drift detection routines that compute host state divergence and perform instant atomic generation rollbacks within three seconds.

== T - Trend Alignment
The project aligns with contemporary campus computing standards:
- *Infrastructure as Code (IaC)*: Extends GitOps and declarative configuration management from cloud infrastructure to institutional workstations and student labs.
- *Immutable Operating Systems*: Implements ephemeral root filesystems (`tmpfs`) and synthetic APFS firmlinks to eliminate persistent system corruption and student tampering.
- *Zero Trust Architecture (ZTA)*: Enforces continuous cryptographic identity verification, outbound-only mTLS connections, and peer-to-peer WireGuard transport without opening inbound campus perimeter firewall ports.

== S - Social / Industrial Impact
- *Cost Optimization*: Eliminates recurring licensing fees for expensive commercial management suites (Intune, SCCM, Jamf Pro, Deep Freeze), saving vital academic funds.
- *Bandwidth Efficiency*: Reduces campus internet bandwidth consumption by up to 90% via local LAN chunk swarming during large-scale lab software rollouts.
- *Lab Hygiene*: Prevents persistent student malware infections and configuration drift through ephemeral root reboots and continuous drift detection.
- *Operational Simplicity*: Empowers academic IT staff to administer multi-platform computing environments across diverse departments through a unified, reproducible codebase.

#v(0.4em)

= 7. Expected Outcomes <sec:outcomes>

The project will deliver the following technical artifacts:
- A high-performance central host service (`shepherd`) written in Go 1.23 with gRPC services, embedded DERP relay, and administrative audit logging.
- Native, low-overhead endpoint client agents (`shepherd-srv`) for Linux, macOS, and Windows.
- A production-grade unified Nix Flake repository template containing host modules for NixOS, nix-darwin, and Windows generation engines.
- A functional peer-to-peer binary distribution engine that streams verified closure chunks across local network peers.
- An automated drift detection and atomic rollback mechanism that detects unauthorized host modifications and restores verified state within three seconds.
- Comprehensive benchmark documentation evaluating configuration convergence time, WAN bandwidth savings, and rollback reliability.

#v(0.4em)

= 8. Implementation Timeline <sec:timeline>

The project implementation follows a structured five-phase development schedule:

#v(0.4em)

#align(center)[
  #table(
    columns: (3.5cm, 1fr),
    stroke: 0.5pt + black,
    inset: (x: 10pt, y: 7pt),
    align: (center + horizon, left + horizon),
    table.header(
      [*Phase*], [*Activity*]
    ),
    [*Phase 1\ (Weeks 1–3)*], [Requirement analysis, declarative schema design, and local multi-OS lab testbed configuration.],
    [*Phase 2\ (Weeks 4–7)*], [Central host service (`shepherd`) development in Go 1.23, PostgreSQL 16 schema design, and Nix Flake evaluator pipeline.],
    [*Phase 3\ (Weeks 8–11)*], [Native client agents (`shepherd-srv`) development: Linux tmpfs root, macOS APFS/MDM, and Windows Win32/LGPO reconcilers.],
    [*Phase 4\ (Weeks 12–14)*], [Tailcat WireGuard userspace mesh integration, DERP relay deployment, and FastCDC LAN P2P swarming.],
    [*Phase 5\ (Weeks 15–16)*], [End-to-end integration testing, drift detection evaluation, performance benchmarking, and synopsis presentation.],
  )
]

#pagebreak()

= 9. References <sec:references>

+ E. Dolstra, "The Purely Functional Software Deployment Model," Ph.D. dissertation, Department of Information and Computing Sciences, Utrecht University, Utrecht, Netherlands, 2006.
+ J. A. Donenfeld, "WireGuard: Next Generation Kernel Network Tunnel," in _Proceedings of the Network and Distributed System Security Symposium (NDSS)_, San Diego, CA, USA, 2017.
+ Apple Inc., "Mobile Device Management Protocol Reference," _Apple Developer Documentation_, Cupertino, CA, USA, Tech. Rep., 2024.
+ Microsoft Corporation, "[MS-GPREG]: Group Policy: Registry Extension Encoding," _Microsoft Open Specifications_, Redmond, WA, USA, Tech. Rep., 2024.
+ W. Xia, H. Jiang, D. Feng, F. Douglis, P. Shilane, M. Hua, G. Min, Y. Zhang, and B. Mao, "FastCDC: A Fast and Efficient Content-Defined Chunking Approach for Data Deduplication," in _Proceedings of the 2016 USENIX Annual Technical Conference (USENIX ATC 16)_, Denver, CO, USA, 2016, pp. 101–114.
+ Google LLC, "gRPC: A High Performance, Open Source Universal RPC Framework," _gRPC Project Documentation_, 2023. [Online]. Available: https://grpc.io
+ Tailscale Inc., "How Tailscale Works: An In-Depth Architecture Overview," _Tailscale Engineering Documentation_, 2023. [Online]. Available: https://tailscale.com/blog/how-tailscale-works
+ PostgreSQL Global Development Group, "PostgreSQL 16.0 Documentation," _The PostgreSQL Global Development Group_, 2024. [Online]. Available: https://www.postgresql.org/docs/16/
+ National Institute of Standards and Technology (NIST), "Zero Trust Architecture," _NIST Special Publication 800-207_, Gaithersburg, MD, USA, Tech. Rep., Aug. 2020.
+ Aerospace, Security and Defence Industries Association of Europe (ASD), "Simplified Technical English: Specification ASD-STE100," _ASD Standard_, Brussels, Belgium, Issue 8, Jan. 2021.
