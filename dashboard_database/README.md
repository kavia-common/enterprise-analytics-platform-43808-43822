# dashboard_database (PostgreSQL)

This container runs PostgreSQL and bootstraps the **enterprise analytics platform** schema (multi-tenancy + RBAC, dashboards/widgets, ingestion/events, audit logs).

## Startup flow

`startup.sh`:
1. Starts PostgreSQL (port is hardcoded in the script today).
2. Creates database + application user, grants permissions.
3. Writes connection command to `db_connection.txt` (authoritative connection string).
4. Writes env file for the DB visualizer to `db_visualizer/postgres.env`.
5. Runs:
   - `migrate.sh` (DDL schema)
   - `seed.sh` (baseline demo data)

Both `migrate.sh` and `seed.sh` are **idempotent** and safe to re-run.

## Connection

Use the command saved in:

- `db_connection.txt` (example):
  - `psql postgresql://appuser:dbuser123@localhost:5000/myapp`

## Schema overview (public schema)

- Multi-tenancy + RBAC:
  - `organizations`, `workspaces`, `users`
  - `roles`, `permissions`, `role_permissions`
  - `workspace_memberships`
- Dashboards:
  - `dashboards`, `widgets`
- Ingestion:
  - `ingestion_sources`, `events`
- Audit:
  - `audit_logs`
- Migrations ledger:
  - `schema_migrations`

## Notes

- The schema uses UUID primary keys and `pgcrypto` (`gen_random_uuid()`).
- Most flexible configuration columns use JSONB (`layout`, `filters`, `query`, `config`, `payload`, etc.).
- Indexes exist for common access patterns (workspace/time lookups for events and audit logs).
