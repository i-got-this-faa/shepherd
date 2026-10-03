# Unified Shepherd Flake

Home for GUI-generated Nix, separate custom modules, and the core aggregator
that includes both. Windows output is finalized signed JSON. The Linux package
format and activation path remain open decisions.

Use `generated/`, `custom/`, and `modules/` when their first source files are
added. Do not merge generated configuration into user-owned custom source.
