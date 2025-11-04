# Azure PDS Target Architecture

## Context from the Reference Implementation

- `@atproto/pds` runs as a long-lived Node.js service that bundles HTTP APIs, background queues, and WebSockets. The service is usually shipped via the container image `ghcr.io/bluesky-social/pds`.
- Durable data is stored on the local filesystem using SQLite databases (`account.sqlite`, `sequencer.sqlite`, `did_cache.sqlite`) and per-user repository directories with blobs when `PDS_BLOBSTORE_DISK_LOCATION` is set. S3-compatible blob stores are optional but not required.
- Optional integrations include Redis (scratch space), SMTP email, and KMS-backed PLC rotation keys. None are strictly required for a functional single-tenant PDS.
- TLS automation and wildcard host routing in the reference deployment are handled by a colocated Caddy proxy that terminates HTTPS and forwards traffic to the PDS service.

## Goals and Design Principles

1. **Cost efficiency** – prefer consumption-based or storage-only services; avoid infrastructure that bills per provisioned hour where alternatives exist.
2. **Low operational overhead** – rely on managed Azure services for compute, storage, and secret management; minimize the need to operate VMs or Kubernetes clusters.
3. **Parity with upstream behaviour** – keep the runtime, filesystem layout, and environment variables consistent with the upstream PDS so upgrades remain straightforward.

## High-Level Architecture

| PDS Capability | Azure Service | Notes |
| --- | --- | --- |
| Container runtime for PDS and Caddy | Azure Container Apps (ACA) on consumption plan | Single container app with two containers (`pds`, `caddy`) sharing a volume. ACA handles ingress, scale, and revisions without VM management. |
| Persistent filesystem for SQLite DBs, repo storage, and blobstore | Container Apps emptyDir volume with snapshot sidecar to Azure Blob Storage | Local volume restored from latest snapshot on startup; backup agent streams periodic archives to blob storage for durability. |
| Secrets (JWT, admin password, storage keys) | Azure Key Vault | Stored as secrets; ACA uses managed identity to read them and injects into environment variables. |
| SMTP email delivery | Azure Communication Services Email (SMTP) or verified SendGrid account | Configure `PDS_EMAIL_SMTP_URL` and related env vars; both options are consumption-based. |
| DNS and TLS for wildcard handles | Azure DNS zone + ACA managed custom domain certificate | Use `pds.example.com` as the service host and create a wildcard CNAME (`*.pds.example.com`) pointing at the ACA default domain; ACA issues a managed certificate for the apex host. |
| Monitoring & logs | Azure Monitor (Log Analytics workspace) + Container Apps diagnostics | Centralized logs, metrics, and alerts without running your own logging stack. |
| Backup automation | Snapshot sidecar within Container App | Restores latest archive on startup and continuously uploads compressed filesystem backups to Azure Blob Storage. |

### Deployment Topology

```
+---------------------------+          +-------------------+
|  Azure DNS (Zone)         |          | Azure Key Vault   |
|  CNAME: *.pds.example.com |          | Secrets: JWT, ... |
+-------------+-------------+          +-------------------+
              |                                     ^
              v                                     |
+-------------+-------------+          +------------+-------------+
|  Azure Container Apps      |   sync  |  Azure Storage Account   |
|  Environment               +<------>+  Blob container (snapshots)|
|  Container App             |         +---------------------------+
|   - caddy container        |
|   - pds container          |
|   - snapshot-agent sidecar |
|  External ingress (HTTPS)  |
+-------------+--------------+
              |
              v
      Client browsers / apps
```

## Detailed Component Design

### Azure Container Apps

- Create a Container Apps environment (consumption plan) in a resource group dedicated to the PDS deployment. The consumption plan charges based on vCPU/memory seconds and concurrent requests, avoiding fixed per-hour costs.
- Define one container app with three containers:
  - `pds`: image `ghcr.io/bluesky-social/pds:<tag>` with port `2583` exposed internally only. Environment variables mirror upstream `.env` expectations.
  - `caddy`: image `caddy:2`. Configure it with the same `Caddyfile` as the reference compose setup to terminate TLS, manage ACME certificates, and proxy traffic to `http://localhost:2583`.
  - `snapshot-agent`: base image `mcr.microsoft.com/azure-cli`. A bootstrap script restores the most recent snapshot archive before signalling readiness, then runs a continuous loop that captures SQLite backups, packages the filesystem with `tar + zstd`, and uploads archives to Azure Blob Storage.
- Use an `EmptyDir` volume mounted at `/pds` for the PDS and Caddy containers. The snapshot agent mounts the same volume at `/data` plus a secret-backed volume containing the helper scripts.
- On cold start the snapshot agent downloads the latest archive (if any), extracts it into `/data`, and writes a sentinel that allows the PDS container to launch. During runtime it emits archives at a configurable interval (default 15 seconds) and prunes older blobs based on retention count.
- Enable external ingress on port `443`. All inbound traffic reaches Caddy, which then forwards to the PDS process. WebSocket support is maintained because ACA supports HTTP/1.1 upgrades.
- Configure a minimum replica count of 1 (PDS must remain online) and allow the app to scale to zero only during planned maintenance windows.

### Storage Layout

Within the shared volume the directory layout matches upstream defaults:

```
/pds
  |-- account.sqlite           # Account DB (checkpointed via .backup)
  |-- sequencer.sqlite         # Sequencer DB
  |-- did_cache.sqlite         # DID cache DB
  |-- actors/                  # Per-user repo SQLite + keys
  |-- blobs/                   # Disk blobstore root (configure PDS_BLOBSTORE_DISK_LOCATION)
  |-- caddy/                   # ACME data and Caddy config/state
```

- At runtime the data lives on the Container Apps node's local SSD (`EmptyDir`).
- The snapshot agent stages a copy of this tree, replaces every `*.sqlite` with an online backup (`sqlite3 .backup`), removes WAL/SHM files, then creates a compressed archive (`snap-<timestamp>.tar.zst`).
- Archives are written to `https://<storage-account>.blob.core.windows.net/<snapshotContainerName>/<snapshotPrefix>/<namePrefix>/` with a configurable retention count (default 200).
- On startup, the agent restores from the most recent archive before the PDS container initializes, yielding RPO ≈ snapshot interval and RTO ≈ download+extract time.

### Secrets and Configuration

- Store the following secrets in Key Vault and map them to environment variables using ACA secret references:
  - `PDS_JWT_SECRET`
  - `PDS_ADMIN_PASSWORD`
  - `PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX` (if not using AWS KMS)
  - `AZURE_STORAGE_ACCOUNT_KEY` (used by ACA to mount the file share)
  - SMTP credentials or connection string
- Use managed identity on the container app to grant read access to Key Vault secrets.
- The runtime `.env` values should include:
  - `PDS_BLOBSTORE_DISK_LOCATION=/pds/blobs`
  - `PDS_BLOBSTORE_DISK_TMP_LOCATION=/pds/blobs/tmp`
  - `PDS_DATA_DIRECTORY=/pds`
  - `PDS_ACTOR_STORE_DIRECTORY=/pds/actors`
  - `PDS_SQLITE_DISABLE_WAL_AUTO_CHECKPOINT=true` (recommended for networked file shares)
  - `PDS_EMAIL_SMTP_URL`, `PDS_EMAIL_FROM_ADDRESS`
  - `PDS_DID_PLC_URL=https://plc.directory`
  - `PDS_HOSTNAME=pds.example.com`

### Networking and TLS

- Create a public DNS zone in Azure DNS for `pds.example.com` (or another subdomain). Add:
  - `CNAME pds.example.com -> <container-app-default-hostname>`
  - `CNAME *.pds.example.com -> <container-app-default-hostname>` for handle subdomains.
- Enable a managed certificate on the container app for `pds.example.com`. For the wildcard, supply a wildcard certificate obtained via Caddy’s ACME flow (stored on the shared volume) or import a certificate into Key Vault and bind it to the custom domain on ACA.
- Restrict ingress to HTTPS and configure the container app’s IP restriction rules if you operate an entryway or need admin access control.

### Observability and Operations

- Connect the container app to a Log Analytics workspace to ingest STDOUT/STDERR from both containers. Create Kusto queries and alerts for health endpoints, error logs, or unexpected restarts.
- Use Azure Monitor metrics for CPU/memory to right-size the app’s min/max replica counts.
- Monitor snapshot-agent metrics and logs to ensure archives continue to upload within the expected interval. Configure alerts on upload failures or lagging snapshots.
- Maintain IaC (Bicep or Terraform) describing the resource group, storage account, container app, identity, and DNS records. Integrate with GitHub Actions to redeploy when a new PDS container tag is released. Updates become a revision swap instead of in-place mutations.

## Cost Considerations

- **Container Apps Consumption** bills only for active usage (vCPU-seconds, memory-seconds, request counts). Keeping a single 0.5 vCPU / 1 GiB replica online results in low monthly cost relative to VMs or AKS nodes.
- **Azure Blob Storage (snapshots)** charges only for occupied capacity and per-request operations. Archives are compressed with `zstd`, and retention count keeps long-term storage predictable.
- **Key Vault** and **Azure DNS** incur minimal monthly fees and remove the need for self-managed PKI or DNS infrastructure.
- Optional services like Azure Cache for Redis or Azure Front Door are omitted by default to avoid hourly charges. Introduce them only if traffic growth warrants the expense.

## Upgrade and Recovery Strategy

1. Use ACA revisions: deploy a new revision referencing the latest `ghcr.io/bluesky-social/pds` tag, validate via health probes, then set it active.
2. Store the `pds.env` template in source control (without secrets) so configuration drift is visible.
3. In a disaster scenario, provision a new container app, supply the storage account key/SAS, and allow the snapshot agent to restore the latest archive before promoting the app. Update DNS CNAMEs once health checks pass.

## Future Enhancements

- Integrate Azure Active Directory B2C or other OAuth providers by customizing PDS OAuth settings once federated entryways are required.
- Add an optional Azure Cache for Redis instance (Basic tier) if rate limiting or OAuth flows demand higher throughput.
- Explore replacing the Caddy sidecar with Azure Front Door if global Anycast ingress or Web Application Firewall rules become requirements (accepting the additional per-hour cost trade-off).
