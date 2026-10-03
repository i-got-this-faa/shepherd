# Binary cache deployment

Attic configuration and deployment belong here. The selected backing object
service is self-hosted FBS, owned by `infra/storage/fbs/`. Pin its upstream
revision or image digest when wiring the deployment, and keep persistent data
and credentials outside the source tree.

Custom endpoint, path-style S3, signing, multipart, presigned node reads, and
Nix cache publication/substitution must be verified in
`tests/storage/attic-fbs/`. No deployment or compatibility test exists yet.
