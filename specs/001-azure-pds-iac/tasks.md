# Tasks: Azure PDS Infrastructure Automation

## Phase 1 – Setup

- [X] T001 Initialize branch `001-azure-pds-iac` and verify tooling prerequisites in specs/001-azure-pds-iac/plan.md
- [X] T002 Capture required Azure CLI/Bicep versions in docs/quickstart.md
- [X] T003 Draft operator environment prerequisites in docs/env-setup.md (no secrets)

## Phase 2 – Foundational

- [X] T004 Validate infra/main.bicep via `bicep build` and resolve lint warnings
- [X] T005 Prepare docs/ directory structure for quickstart and validation guides
- [X] T006 Create tests/what-if/us1-deploy.sh baseline script referencing infra/main.bicep

## Phase 3 – User Story 1: Deploy baseline environment (Priority P1)

- [X] T007 [US1] Expand infra/main.bicep to include Azure Automation account and runbook resources
- [X] T008 [US1] Add parameters and outputs in infra/main.bicep for automation schedule configuration
- [X] T009 [P] [US1] Update docs/quickstart.md with deployment and automation setup steps
- [X] T010 [P] [US1] Implement tests/what-if/us1-deploy.sh to run `az deployment group what-if`
- [X] T011 [US1] Document deployment verification checklist in docs/verification.md
- [X] T012 [US1] Capture deployment timing checklist in docs/verification.md
- [X] T013 [US1] Document namePrefix collision remediation steps in docs/verification.md

## Phase 4 – User Story 2: Externalize secrets and configuration (Priority P2)

- [X] T014 [US2] Update infra/main.bicep to ensure managed identity policy grants Key Vault secret access
- [X] T015 [P] [US2] Author docs/secrets.md detailing Key Vault secret creation workflow
- [X] T016 [P] [US2] Provide scripts/kv-populate.sh template for operators (no secrets committed)
- [X] T017 [US2] Document secret rotation and restart steps in docs/secrets.md
- [X] T018 [P] [US2] Add scripts/secrets-audit.sh template and guidance for repository secret scanning

## Phase 5 – User Story 3: Validate post-deployment readiness (Priority P3)

- [X] T019 [US3] Create docs/validation.md covering health checks and log inspection
- [X] T020 [US3] Enhance tests/what-if/us1-deploy.sh to invoke verification commands post-deploy
- [X] T021 [US3] Document DNS configuration instructions in docs/dns.md
- [X] T022 [US3] Extend docs/validation.md with success-rate logging to meet SC-002

## Phase 6 – Polish & Cross-Cutting

- [X] T023 Review and tighten parameter validation defaults in infra/main.bicep
- [X] T024 Ensure docs/quickstart.md, docs/secrets.md, and docs/validation.md reference deployment outputs consistently
- [X] T025 Final run-through of tests/what-if/us1-deploy.sh and sample deployment commands for QA sign-off

## Dependencies

1 → 2 → 3 → 4 → 5 → 6 (Phases executed sequentially)

- Phase 3: T009 and T010 can run in parallel once T007/T008 complete.
- Phase 4: T015, T016, and T018 can proceed simultaneously after T014.

## Independent Test Criteria by User Story

- **US1**: Successful deployment and what-if outputs match expectations, automation runbook resources present.
- **US2**: Operators can populate secrets without modifying IaC and container app ingests secrets from Key Vault.
- **US3**: Documented validation steps confirm service health and DNS resolution post-deployment.

## MVP Scope

Deliver Phase 3 (US1) as initial MVP: infrastructure deployment with automation runbook and verification scripts.

## Implementation Strategy

1. Complete setup and foundational tasks to establish structure.
2. Implement US1 end-to-end to achieve deployable infrastructure baseline.
3. Layer secret externalization (US2) and validation enhancements (US3).
4. Finish with polish tasks ensuring documentation and templates align with deployment outputs.
