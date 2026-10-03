import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

DIAGRAMS = {
    "diagram_topology": """flowchart TB
  subgraph Server["Shepherd Central Infrastructure (Go 1.23 Engine)"]
    direction TB
    Flake["Unified Nix Flake\n(Git Repo)"] --> Eval["Nix Evaluator\n(Pure Derivations)"]
    Eval --> Core["Shepherd Core Server\n(gRPC & Tailcat DERP)"]
    Core <--> DB[("PostgreSQL 16\nState & Drift Log")]
    Core --> NanoMDM["NanoMDM\n(Apple APNs Engine)"]
    Eval --> Attic[("Attic S3 Store\nSigned Binary Cache")]
  end

  subgraph Endpoints["Managed Endpoints (Tailcat WireGuard Mesh)"]
    subgraph Linux["Linux Host (NixOS)"]
      L_Ag["shepherd-srv (Linux)\nDrift Detector"] --> L_St["/nix/store\n(tmpfs root)"]
    end

    subgraph Mac["macOS Host (Darwin)"]
      M_Ag["shepherd-srv (Darwin)\nDrift Detector"] --> M_St["/nix/store\n(APFS Firmlink)"]
      M_MDM["Apple MDM\nClient"] --> M_Sec["FileVault\n& TCC"]
    end

    subgraph Win["Windows Host (NTFS)"]
      W_Ag["shepherd-srv (Win32)\nDrift Detector"] --> W_Gn["generations/\n(Registry & LGPO)"]
    end
  end

  Core ==>|"gRPC: Hashes & Drift"| L_Ag
  Core ==>|"gRPC: Hashes & Drift"| M_Ag
  Core ==>|"gRPC: Hashes & Drift"| W_Ag

  NanoMDM -.->|"Apple APNs"| M_MDM

  Attic -.->|"Signed NARs"| L_St
  Attic -.->|"Signed NARs"| M_St
  Attic -.->|"Signed NARs"| W_Gn

  classDef server fill:#ffffff,stroke:#0969da,stroke-width:2px,color:#1f2328;
  classDef agent fill:#ffffff,stroke:#1a7f37,stroke-width:2px,color:#1f2328;
  classDef storage fill:#ffffff,stroke:#9a6700,stroke-width:2px,color:#1f2328;
  classDef mdm fill:#ffffff,stroke:#8250df,stroke-width:2px,color:#1f2328;

  class Flake,Eval,Core server;
  class L_Ag,M_Ag,W_Ag agent;
  class DB,Attic,L_St,M_St,W_Gn storage;
  class NanoMDM,M_MDM,M_Sec mdm;
""",

    "diagram_network_mesh": """flowchart TB
  subgraph Server["Shepherd Central Infrastructure (Go 1.23 Engine)"]
    direction TB
    Core["Shepherd Core Engine\n(Target Hashes & Telemetry)"]
    DERP["Embedded DERP Relay\n(HTTPS 443 Fallback)"]
    Attic[("Attic S3 Store\n(Master Binary Cache)")]
    Core --> DERP
    Core --> Attic
  end

  subgraph Endpoints["Tailcat WireGuard Mesh (All Nodes)"]
    subgraph Remote["Remote Machines (WAN)"]
      R_Direct["Direct Peer\n(Home Wi-Fi)"]
      R_Relay["Restricted NAT\n(DERP HTTPS)"]
    end
    subgraph Office["Lab Machines (LAN Transfer)"]
      NodeA["Peer 1\n(S3 Fetcher)"]
      NodeB["Peer 2\n(LAN Receiver)"]
      NodeA -->|"LAN P2P Chunk Stream"| NodeB
    end
  end

  Core ==>|"Target Hash Broadcast"| R_Direct
  Core ==>|"Target Hash Broadcast"| R_Relay
  Core ==>|"Target Hash Broadcast"| NodeA

  DERP -.->|"HTTPS 443 Tunnel"| R_Relay
  Attic -.->|"Signed Upstream Closures"| NodeA

  classDef server fill:#ffffff,stroke:#0969da,stroke-width:2px,color:#1f2328;
  classDef remote fill:#ffffff,stroke:#1a7f37,stroke-width:2px,color:#1f2328;
  classDef office fill:#ffffff,stroke:#9a6700,stroke-width:2px,color:#1f2328;
  classDef derp fill:#ffffff,stroke:#8250df,stroke-width:2px,color:#1f2328;

  class Core,Attic server;
  class DERP derp;
  class R_Direct,R_Relay remote;
  class NodeA,NodeB office;
""",





    "diagram_cache_sequence": """sequenceDiagram
  autonumber
  actor Admin as Admin
  participant Server as Shepherd Server
  participant Farm as Build Farm
  participant Attic as Attic S3
  participant A as Node A (LAN)
  participant B as Node B (LAN)

  Admin->>Server: Git push Flake lock
  Server->>Farm: Trigger nix build
  Farm->>Attic: Upload signed NARs
  Server->>A: Send target hash (gRPC)
  Server->>B: Send target hash (gRPC)

  Note over A,Attic: Node A fetches from S3
  A->>Attic: Pull missing store paths
  A->>A: Verify Ed25519 & activate

  Note over A,B: Node B fetches via LAN P2P
  B->>A: Request chunks (WireGuard)
  A-->>B: Stream chunks over LAN
  B->>B: Verify Ed25519 & activate
""",

    "diagram_linux_workflow": """flowchart TB
  subgraph Stage1["1. Download & Store Verification"]
    direction LR
    Target["Target Hash\n(gRPC 443)"] --> Pull["Pull Signed Closure\n(Attic S3 / LAN P2P)"]
    Pull --> Store["Write /nix/store\n(Verify Ed25519)"]
  end

  subgraph Stage2["2. Activation & Symlink Switch"]
    direction LR
    Symlink["Update Symlink\n(/run/current-system)"] --> Switch["Run Activation Script\nswitch-to-configuration"]
  end

  subgraph Stage3["3. Validation & Rollback"]
    direction LR
    Health{"Health Check\nPass?"}
    Health -- Pass --> Report["Report Active\n(Generation N Valid)"]
    Health -- Fail --> Revert["Rollback Symlink\n(Generation N-1 Restored)"]
  end

  Stage1 --> Stage2 --> Stage3
""",

    "diagram_macos_workflow": """flowchart LR
  subgraph MDMChannel["Apple MDM Channel (Security)"]
    direction TB
    NanoMDM["Embedded NanoMDM"] --> APNs["Apple APNs Push"]
    APNs --> AppleClient["macOS MDM Framework"]
    AppleClient --> Security["FileVault Escrow & TCC Profiles"]
  end

  subgraph FleetChannel["Shepherd Agent Channel (Software)"]
    direction TB
    DarwinHash["Target Darwin Hash"] --> FetchClosure["Fetch Closure (Tailcat / S3)"]
    FetchClosure --> DarwinStore["Write /nix/store (Firmlink)"]
    DarwinStore --> Activate["Run darwin-rebuild activate"]
    Activate --> SystemState["LaunchDaemons, Plists & Apps"]
  end

  MDMChannel ~~~ FleetChannel
""",

    "diagram_windows_workflow": """flowchart TB
  subgraph Stage1["1. Central Server Evaluation"]
    direction LR
    Flake["Unified Nix Flake"] --> Eval["Server Evaluator"]
    Eval --> IR["Desired State IR JSON"]
  end

  subgraph Stage2["2. Local Reconciler Engine"]
    direction LR
    Bundle["Write Bundle\nC:\\ProgramData\\Shepherd\\generations"] --> Apply["Apply State:\n• Win32 Registry Hives\n• LGPO .pol Files\n• Winget Packages\n• Windows Services"]
  end

  subgraph Stage3["3. Verification & Automated Rollback"]
    direction LR
    Check{"Health Check\nPass?"}
    Check -- Pass --> Active["Update Pointer to Hash\n(Generation N Active)"]
    Check -- Fail --> Rollback["Re-run Generation N-1 Bundle\n(Instant Idempotent Revert)"]
  end

  Stage1 --> Stage2 --> Stage3
""",

    "diagram_canary_rings": """flowchart TB
  subgraph Phase1["Phase 1: Canary (Ring 0)"]
    direction LR
    R0["Ring 0: 1% Fleet (24h)"] --> C0{"24hr Error = 0?"}
    C0 -- Pass --> Promote0["Promote to Ring 1"]
    C0 -- Fail --> Rev0["Auto-Revert Ring 0"]
  end

  subgraph Phase2["Phase 2: Early Adopters (Ring 1)"]
    direction LR
    R1["Ring 1: 10% Fleet (48h)"] --> C1{"48hr Health Pass?"}
    C1 -- Pass --> Promote1["Promote to Ring 2"]
    C1 -- Fail --> Rev1["Auto-Revert Ring 1"]
  end

  subgraph Phase3["Phase 3: Production (Ring 2)"]
    direction LR
    R2["Ring 2: 100% General Fleet"] --> Stable["Full Campus Fleet Stable"]
  end

  Phase1 --> Phase2 --> Phase3
""",

    "diagram_dashboard": """flowchart TB
  subgraph Endpoints["1. Shepherd Endpoints"]
    direction LR
    L["Linux Nodes"] --- M["macOS Nodes"] --- W["Windows Nodes"]
  end

  subgraph Engine["2. Go Telemetry Engine"]
    direction LR
    Stream["gRPC / WS Server"]
    Prom["Prometheus Engine"]
    LLM["LLM Summarizer"]
    PG[("PostgreSQL 16\n(TimescaleDB)")]
    Stream --> PG & Prom
    Prom --> LLM
  end

  subgraph Console["3. Shepherd Web Console (Next.js 16)"]
    direction LR
    Inv["Host Inventory & Generations"]
    Drift["Drift Detection & 1-Click Revert"]
    Alerts["AI Insights & Recommended Tweaks"]
  end

  Endpoints ==>|Telemetry & Heartbeats| Stream
  Engine ==>|Real-time WebSockets| Console
  Console -.->|Revert Commands| Stream
"""
}

def render_diagram(name, mmd_code):
    html_content = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
<style>
  body {{
    background-color: #ffffff;
    margin: 0;
    padding: 16px;
    display: flex;
    justify-content: center;
    align-items: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }}
  .nodeLabel {{
    font-size: 22px !important;
    font-weight: 600 !important;
    line-height: 1.3 !important;
    color: #1f2328 !important;
  }}
  .edgeLabel {{
    font-size: 18px !important;
    font-weight: 700 !important;
    color: #0969da !important;
    background-color: #ffffff !important;
    padding: 3px 6px !important;
    border-radius: 4px !important;
  }}
  .cluster-label .nodeLabel {{
    font-size: 24px !important;
    font-weight: 700 !important;
    color: #0969da !important;
  }}
</style>
</head>
<body>
<div class="mermaid">
{mmd_code}
</div>
<script>
mermaid.initialize({{
  startOnLoad: true,
  theme: 'default',
  themeVariables: {{
    darkMode: false,
    background: '#ffffff',
    primaryColor: '#ffffff',
    primaryTextColor: '#1f2328',
    primaryBorderColor: '#0969da',
    lineColor: '#0969da',
    secondaryColor: '#f6f8fa',
    tertiaryColor: '#f6f8fa',
    fontSize: '18px'
  }}
}});
</script>
</body>
</html>
"""
    tmp_html = f"/tmp/{name}.html"
    with open(tmp_html, "w") as f:
        f.write(html_content)

    chrome_cmd = [
        "/home/radhey/.local/bin/google-chrome-stable",
        "--headless",
        "--no-sandbox",
        "--disable-gpu",
        "--virtual-time-budget=6000",
        "--dump-dom",
        f"file://{tmp_html}"
    ]
    
    res = subprocess.run(chrome_cmd, capture_output=True, text=True)
    out_html = res.stdout

    if 'aria-roledescription="error"' in out_html:
        raise ValueError(f"Mermaid syntax error detected in {name}!")

    # Extract SVG
    svg_match = re.search(r'(<svg[^>]*id="mermaid-[^"]*"[^>]*>.*?</svg>)', out_html, re.DOTALL)
    if not svg_match:
        svg_match = re.search(r'(<svg[^>]*>.*?</svg>)', out_html, re.DOTALL)
        
    if svg_match:
        svg_code = svg_match.group(1)
        # Ensure proper XML namespace if missing
        if "xmlns=" not in svg_code:
            svg_code = svg_code.replace("<svg", '<svg xmlns="http://www.w3.org/2000/svg"')
        # Fix void tags that break XML parser
        svg_code = svg_code.replace("<br>", "<br/>")
        svg_code = svg_code.replace("<hr>", "<hr/>")
        
        # Validate XML
        try:
            ET.fromstring(svg_code)
            valid = True
        except Exception as e:
            print(f"Warning: XML validation failed for {name}: {e}")
            valid = False
            
        out_svg = Path(__file__).resolve().parent.parent / "assets" / f"{name}.svg"
        with open(out_svg, "w") as f:
            f.write(svg_code)
        print(f"Generated {out_svg} ({len(svg_code)} bytes, XML valid: {valid})")
    else:
        print(f"Failed to find SVG for {name}")

for name, code in DIAGRAMS.items():
    render_diagram(name, code)
