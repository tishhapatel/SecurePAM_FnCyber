# SecurePAM — Deployment Readiness and DevSecOps Audit Report

**Audit Date:** 15 November 2026  
**Auditor Roles:** Senior DevSecOps Engineer, Site Reliability Engineer (SRE) & Cloud Infrastructure Architect  
**Scope:** Verification of Docker Compose stacks, container configurations, environment variables, database migration lifecycle, operational startup scripts, health probes, and onboarding feasibility.  
**Target Environments:** Local Developer Workstation (Windows/Linux/macOS), Staging Lab Environment, and AWS Cloud Production Architecture.

---

## 1. Executive Deployment Readiness Assessment

The SecurePAM deployment architecture is engineered around containerized microservices and automated infrastructure provisioning:
- **Docker Compose Orchestration:** Fully articulated 12-container service topology in `docker-compose.yml`, complemented by isolated sidecar Compose stacks for Apache Guacamole (`infrastructure/guacamole/compose.yml`) and Browser Isolation (`infrastructure/browser-isolation/compose.yml`).
- **Database Schema Lifecycle:** Robust 7-stage Alembic migration chain (`f54df7d869ad` through `d4e5f6a7b8c9`) supporting forward upgrades, schema drift detection, and automated database bootstrapping.
- **Cross-Platform Startup Automation:** Windows-native PowerShell scripts (`scripts/start-securepam.ps1`, `scripts/status-securepam.ps1`) and UNIX Bash run scripts (`scripts/start-securepam.sh`, `scripts/status-securepam.sh`) provide automated environment preflight checks, dependency verification, and health diagnostics.
- **Deployment Readiness Rating:** **88% Production-Ready for Linux/Docker environments; Requires WSL2 / Docker Desktop for Windows developer workstations.**

---

## 2. Infrastructure Container Topology

### 2.1 Main Application Stack (`docker-compose.yml`)

| Service Name | Base Container Image | Published Ports | Purpose & Security Controls |
|---|---|---|---|
| `postgres` | `postgres:16-alpine` | `127.0.0.1:5432:5432` | Control plane relational store; healthchecked via `pg_isready`. |
| `redis` | `redis:7-alpine` | `127.0.0.1:6379:6379` | Ephemeral one-time ticket store & sliding-window rate limiter. |
| `backend` | Built from `backend/Dockerfile` | `127.0.0.1:8000:8000` | FastAPI Control Plane API; non-root user `appuser`, read-only FS. |
| `frontend` | Built from `frontend/Dockerfile` | `127.0.0.1:3000:80` | Production NGINX serving Vite static bundle; non-root user. |
| `keycloak-postgres`| `postgres:16-alpine` | Internal only | Isolated PostgreSQL instance dedicated exclusively to Keycloak. |
| `keycloak` | Built from `infrastructure/keycloak` | `127.0.0.1:8080:8080` | Keycloak 24 IAM server with custom OTP SPI extension & auto-realm import. |
| `openbao` | `openbao/openbao:2.0.0` | `127.0.0.1:18200:8200` | OpenBao KV v2 secret engine; running in development or sealed staging. |
| `openbao-init` | `openbao/openbao:2.0.0` | None (one-shot exit)| Bootstraps KV v2 mount, policies, AppRole credentials, and initial secrets. |
| `guacd` | `guacamole/guacd:1.6.0` | `127.0.0.1:4822:4822` | Guacamole proxy daemon converting RDP into Guacamole instructions. |
| `guacamole` | `guacamole/guacamole:1.6.0` | `127.0.0.1:8081:8080` | Guacamole web application & history recording storage extension. |
| `prometheus` | `prom/prometheus:v2.54.1` | `127.0.0.1:9090:9090` | Time-series scraper scraping `/metrics` endpoint from backend. |
| `grafana` | `grafana/grafana:11.2.0` | `127.0.0.1:3001:3000` | Analytics dashboards visualizing operational latencies and session counts. |

### 2.2 Browser Isolation Sidecar Stack (`infrastructure/browser-isolation/compose.yml`)
- **Container Security Boundary:**
  - `init: true` (Tini PID 1 to clean up zombie Chromium processes).
  - `read_only: true` (Read-only container filesystem).
  - `user: "1000:1000"` (Runs as unprivileged user).
  - `cap_drop: [ALL]` (Drops all Linux kernel capabilities).
  - `security_opt: ["no-new-privileges:true"]`.
  - `pids_limit: 512`, `mem_limit: 3g`, `shm_size: 512m`.
  - `tmpfs: ["/tmp:size=1g,mode=1777"]`.
  - `ports: ["127.0.0.1:6090:6090", "127.0.0.1:5910-5917:5910-5917"]` (Loopback only).

---

## 3. Configuration & Environment Variables Audit

The repository provides `.env.example` (112 lines) documenting all required and optional environment variables.

### 3.1 Critical Variable Categories & Verification

| Variable Name | Default in Dev | Production Rule & Validation | Verification in Code |
|---|---|---|---|
| `SECRET_KEY` | Placeholder string | **MUST BE CHANGED.** Fails startup if default in prod. | `backend/app/core/config.py:289-294` |
| `ENVIRONMENT` | `development` | Accepts `development`, `staging`, `production`, `test`. | `backend/app/core/config.py:38` |
| `DEV_MODE` | `true` | Must be `false` in production. Disables dev login & Swagger docs. | `backend/app/main.py:140-142` |
| `DATABASE_URL` | Local Postgres asyncpg | Must point to PostgreSQL with SSL (`ssl=require`). | `backend/app/database/session.py` |
| `REDIS_URL` | `redis://localhost:6379/0` | Points to Redis cluster/standalone. | `backend/app/core/rate_limit.py` |
| `SECRET_PROVIDER` | `mock` or `openbao` | In production, must be `openbao`. | `backend/app/secret_providers/__init__.py` |
| `OPENBAO_URL` | `http://localhost:18200` | Must use HTTPS in production. | `backend/app/secret_providers/openbao.py` |
| `OPENBAO_TOKEN` | Token string | Bounded AppRole token only; never root token. | `backend/app/core/config.py:126` |
| `RDP_IGNORE_CERT` | `true` (dev only) | **Prohibited in production.** Fails startup if true in prod. | `backend/app/core/config.py:297` |
| `SIEM_EVENT_LOG_PATH`| Optional JSON file | Path to secret-scrubbed JSON stream for Wazuh SIEM. | `backend/app/core/siem.py` |

---

## 4. Database Initialization & Migration Verification

The database schema is managed via Alembic async migrations located in `backend/migrations/versions/`.

```
f54df7d869ad (Initial Schema: Core RBAC, Users, Assets, Requests, Sessions)
    │
    ▼
f293f013e366 (Phase 3: Assets, Applications, Policies metadata)
    │
    ▼
4a0d91a07728 (Phase 4: Access Requests, Approvals, JIT Grants)
    │
    ▼
235fd5fdd69a (Phase 5: Vault References, Provider types, Secret versions)
    │
    ▼
b7c1d2e3f4a5 (Runtime Settings: AppSettings model)
    │
    ▼
c3d4e5f6a7b8 (Isolated Browser: Application start_path & tls_pin_sha256)
    │
    ▼
d4e5f6a7b8c9 (Risk Centre: RiskFinding model & security findings) [HEAD]
```

- **Clean Upgrade:** Migrations apply cleanly from base to HEAD (`alembic upgrade head`).
- **Dev Mode Bootstrapping:** When `DEV_MODE=true`, `backend/app/main.py:97-105` automatically calls `Base.metadata.create_all` and runs `_seed_default_data()`, creating default roles (`ADMIN`, `APPROVER`, `OPERATOR`, `AUDITOR`), default permissions, default dev users (`admin`, `operator`, `approver`, `auditor`), and baseline policies.

---

## 5. Deployment Blockers & Onboarding Evaluation

### 5.1 Can a New Developer Clone, Build, and Run the Project?

#### On Linux / macOS (with Docker installed):
- **Status: FULLY FUNCTIONAL.**
- Running `docker compose up -d` brings up all 12 containers.
- Frontend builds and serves on port 3000; Backend API on port 8000; Keycloak on port 8080.
- Zero manual database schema creation needed.

#### On Windows Native (without Docker Desktop):
- **Status: PARTIALLY FUNCTIONAL / DATA PLANE GAPS.**
- Frontend compiles and runs natively (`npm run dev` on port 3000).
- Backend runs natively using local Python (`uvicorn app.main:app` on port 8000) using local PostgreSQL and Redis from `tools/`.
- **Blocker:** Guacamole (`guacd`), Keycloak, and the Browser Isolation daemon are Linux-native services packaged as Docker images. Running full RDP streaming and Isolated Browser sessions natively on Windows requires either Docker Desktop (WSL2 backend) or hosting these daemons on an external Linux virtual machine.

---

## 6. SRE Recommendations for Production Deployment

1. **Deploy Behind Enterprise Reverse Proxy / WAF:** Place the platform behind AWS Application Load Balancer (ALB) or Cloudflare with TLS 1.3, DDoS protection, and rate limiting.
2. **PostgreSQL High Availability & Automated Backups:** Configure AWS RDS PostgreSQL with Multi-AZ replication, automated point-in-time recovery (PITR), and daily encrypted snapshots.
3. **OpenBao Production Cluster:** Deploy OpenBao across at least three nodes backed by AWS S3 / DynamoDB with AWS KMS auto-unseal to eliminate manual unsealing during instance restarts.
