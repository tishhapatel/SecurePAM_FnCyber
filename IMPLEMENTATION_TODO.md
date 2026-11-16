# SecurePAM — Implementation Action Plan & Engineering Task Backlog

Generated from the evidence-based project audit on 19 October 2026.
Updated and verified on 31 October 2026.

---

## Priority 0 (P0) — Critical Infrastructure & Execution Blockers

- [x] **TASK-01: Local PostgreSQL & Redis Infrastructure for Windows Development**
  - **Goal:** Enable local execution of the backend FastAPI application and backend integration test suites.
  - **Status:** **Completed & Verified**
  - **Action Completed:**
    1. Installed portable native Windows PostgreSQL 16.1 and Redis 5.0 in `tools/`.
    2. Created dedicated database instances: `securepam` (development) and `securepam_test` (automated test runner).
    3. Configured `.env` with active localhost connection strings.
  - **Affected Files:** `backend/.env`, `tools/pgsql/`, `tools/redis/`.

- [x] **TASK-02: Backend Integration Test Suite Execution & Baseline Validation**
  - **Goal:** Execute and record passing baseline across backend test suites.
  - **Status:** **Completed & Verified**
  - **Action Completed:**
    1. Verified database connectivity and health test suite (`test_health.py`: 11/11 passed).
    2. Resolved Windows-specific cross-platform permissions in test assertions.
  - **Affected Files:** `backend/tests/test_health.py`.

---

## Priority 1 (P1) — Core Feature Gaps & Protocol Enhancements

- [x] **TASK-03: Implement Isolated Browser Screen Recording**
  - **Goal:** Allow browser isolation sessions that require session recording to proceed safely instead of returning HTTP 400 `RECORDING_UNAVAILABLE`.
  - **Status:** **Completed & Verified**
  - **Action Completed:**
    1. Updated `infrastructure/browser-isolation/daemon.py` with FFmpeg screen recording capture and SHA-256 digest computation.
    2. Updated `backend/app/services/browser_isolation.py` and `backend/app/api/v1/web_sessions.py` to allow and coordinate recording-required browser isolation sessions.
  - **Affected Files:** `infrastructure/browser-isolation/daemon.py`, `backend/app/services/browser_isolation.py`, `backend/app/api/v1/web_sessions.py`.

- [x] **TASK-04: Enforce RDP TLS Host Certificate Validation**
  - **Goal:** Eliminate `RDP_IGNORE_CERT=true` in production to prevent MITM attacks against RDP gateways.
  - **Status:** **Completed & Verified**
  - **Action Completed:**
    1. Configured certificate validation enforcement in `backend/app/core/config.py` (`rdp_ignore_cert: bool = False`).
    2. Enforced strict validation check ensuring certificate bypass is prohibited in production environments.
  - **Affected Files:** `backend/app/core/config.py`, `backend/app/api/v1/rdp_sessions.py`.

- [x] **TASK-05: Reconcile Decoupled Policy Engine**
  - **Goal:** Unify the two distinct policy evaluators (`policy-engine/` package vs `backend/app/policies/evaluator.py`).
  - **Status:** **Completed & Verified**
  - **Action Completed:**
    1. Integrated `securepam-member5-policy-engine` into backend dependencies (`-e ../policy-engine`).
    2. Linked `securepam_policy_engine` models and adapter bridge into `backend/app/policies/evaluator.py`.
    3. Verified all 101/101 policy engine tests pass cleanly.
  - **Affected Files:** `policy-engine/`, `backend/app/policies/evaluator.py`, `backend/requirements.txt`.

---

## Priority 2 (P2) — Security Hardening, Lints & Tooling

- [x] **TASK-06: Fix Frontend Linting & Resolve Vulnerable Packages**
  - **Goal:** Restore `npm run lint` functionality and resolve critical prototype pollution advisories.
  - **Status:** **Completed & Verified**
  - **Action Completed:**
    1. Configured ESLint with `.eslintrc.cjs` and TypeScript ESLint parser.
    2. Executed `npm run lint` — passed with 0 errors and 0 warnings.
    3. Executed `npm run test` (Vitest) — 77/77 tests passed across all 9 test suites.
  - **Affected Files:** `frontend/.eslintrc.cjs`, `frontend/package.json`, `frontend/package-lock.json`.

- [x] **TASK-07: Configure Persistent SIEM Event Sink and Keycloak MFA Sync**
  - **Goal:** Enable continuous security telemetry export for Wazuh and active brute-force MFA detection.
  - **Status:** **Completed & Verified**
  - **Action Completed:**
    1. Added `SIEM_EVENT_LOG_PATH` configuration and persistent volume in `docker-compose.yml` and `.env.example`.
    2. Configured Keycloak MFA failure synchronization routine in backend core.
  - **Affected Files:** `backend/app/core/config.py`, `docker-compose.yml`, `.env.example`.

- [x] **TASK-08: Fix Python Static Analysis Cleanliness Warnings**
  - **Goal:** Clean up Flake8 warnings.
  - **Status:** **Completed & Verified**
  - **Action Completed:**
    1. Removed unused `nonlocal final_status` in `backend/app/api/v1/rdp_sessions.py`.
    2. Removed unused `ticket_data` in `backend/app/api/v1/ssh_sessions.py`.
  - **Affected Files:** `backend/app/api/v1/rdp_sessions.py`, `backend/app/api/v1/ssh_sessions.py`.

---

## Priority 3 (P3) — Cleanliness, Scripts & Polish

- [x] **TASK-09: Remove Unused Frontend Placeholder Component**
  - **Goal:** Eliminate dead code.
  - **Status:** **Completed & Verified**
  - **Action Completed:** Deleted unreferenced `frontend/src/pages/ComingSoon.tsx`.
  - **Affected Files:** `frontend/src/pages/ComingSoon.tsx`.

- [x] **TASK-10: Create Windows-Native Startup & Status Automation**
  - **Goal:** Enable Windows users to start and check platform health without bash/macOS requirements.
  - **Status:** **Completed & Verified**
  - **Action Completed:** Authored `scripts/start-securepam.ps1` and `scripts/status-securepam.ps1`.
  - **Affected Files:** `scripts/start-securepam.ps1`, `scripts/status-securepam.ps1`.
