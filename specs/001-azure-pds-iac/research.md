# Research Notes: Azure PDS Infrastructure Automation

## Decision: Use resource-group-scoped Bicep deployments driven by Azure CLI
- **Rationale**: Keeps deployment self-contained, aligns with existing `infra/main.bicep`, and supports idempotent updates via `az deployment group create` plus `what-if` validation.
- **Alternatives Considered**: Subscription-scoped deployments (adds cross-RG complexity); Azure DevOps pipelines (would require service connections and is outside current scope).

## Decision: Azure Automation runbook handles daily Azure Files snapshots and exports
- **Rationale**: Automation accounts natively execute PowerShell runbooks with managed identity, enabling scheduled snapshots without per-run costs beyond execution time.
- **Alternatives Considered**: Logic Apps (higher per-execution billing for long-running workflows); Manual procedures (non-compliant with requirement for automated backups).

## Decision: Store operational documentation alongside IaC in `docs/`
- **Rationale**: Co-locating quickstart and verification steps ensures operators have versioned guidance that matches the deployed template.
- **Alternatives Considered**: External wiki (risk of drift); README-only updates (insufficient structure for multi-step runbooks).

## Decision: Validate deployments using `az deployment group what-if` scripts
- **Rationale**: Built-in preview reduces deployment risk and functions as lightweight regression checks without needing a dedicated test framework.
- **Alternatives Considered**: Full integration tests using Azure SDKs (higher maintenance); manual portal review (error-prone).
