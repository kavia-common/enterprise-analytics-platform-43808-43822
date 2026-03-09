#!/bin/bash
set -euo pipefail

# Migration runner for the enterprise analytics platform database.
# Uses db_connection.txt as the authoritative connection string, aligning with startup.sh.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

if [ ! -f "db_connection.txt" ]; then
  echo "❌ db_connection.txt not found. Run startup.sh first."
  exit 1
fi

PSQL_CMD="$(cat db_connection.txt)"

echo "Running migrations using: ${PSQL_CMD}"

# Apply schema + record migration
${PSQL_CMD} <<'SQL'
BEGIN;

-- Track schema versions (simple migration ledger)
CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Ensure crypto helpers for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Core enums
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'audit_action') THEN
    CREATE TYPE public.audit_action AS ENUM (
      'create','update','delete',
      'login','logout',
      'ingest','export',
      'permission_grant','permission_revoke'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'event_status') THEN
    CREATE TYPE public.event_status AS ENUM ('received','processed','failed');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'widget_type') THEN
    CREATE TYPE public.widget_type AS ENUM ('line','bar','area','pie','table','metric','text');
  END IF;
END
$$;

-- =========================
-- Multi-tenancy + RBAC
-- =========================

CREATE TABLE IF NOT EXISTS public.organizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.workspaces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  slug TEXT NOT NULL,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, slug)
);

-- NOTE: This is an application-level user table; auth provider integration is handled by backend.
CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL UNIQUE,
  full_name TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  is_superadmin BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

CREATE TABLE IF NOT EXISTS public.permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE, -- e.g. 'dashboards:read'
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.role_permissions (
  role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  permission_id UUID NOT NULL REFERENCES public.permissions(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (role_id, permission_id)
);

-- Membership is workspace-scoped (typical for analytics apps)
CREATE TABLE IF NOT EXISTS public.workspace_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role_id UUID REFERENCES public.roles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, user_id)
);

-- =========================
-- Dashboards + Widgets
-- =========================

CREATE TABLE IF NOT EXISTS public.dashboards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  layout JSONB NOT NULL DEFAULT '{}'::jsonb, -- grid layout / metadata
  filters JSONB NOT NULL DEFAULT '{}'::jsonb, -- saved filters
  is_shared BOOLEAN NOT NULL DEFAULT FALSE,
  created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.widgets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dashboard_id UUID NOT NULL REFERENCES public.dashboards(id) ON DELETE CASCADE,
  type public.widget_type NOT NULL,
  title TEXT NOT NULL,
  query JSONB NOT NULL DEFAULT '{}'::jsonb,     -- source/query definition
  config JSONB NOT NULL DEFAULT '{}'::jsonb,    -- viz config
  position JSONB NOT NULL DEFAULT '{}'::jsonb,  -- grid position/sizing
  refresh_interval_seconds INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =========================
-- Ingestion + Events
-- =========================

CREATE TABLE IF NOT EXISTS public.ingestion_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  kind TEXT NOT NULL DEFAULT 'http', -- e.g. http, webhook, sdk
  config JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, name)
);

CREATE TABLE IF NOT EXISTS public.events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  source_id UUID REFERENCES public.ingestion_sources(id) ON DELETE SET NULL,
  event_name TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status public.event_status NOT NULL DEFAULT 'received',
  payload JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =========================
-- Audit logs
-- =========================

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID REFERENCES public.workspaces(id) ON DELETE CASCADE,
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  action public.audit_action NOT NULL,
  entity_type TEXT,         -- e.g. 'dashboard', 'widget', 'membership'
  entity_id UUID,
  ip_address INET,
  user_agent TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =========================
-- Helpful indexes
-- =========================

CREATE INDEX IF NOT EXISTS idx_workspaces_org ON public.workspaces(organization_id);

CREATE INDEX IF NOT EXISTS idx_memberships_workspace ON public.workspace_memberships(workspace_id);
CREATE INDEX IF NOT EXISTS idx_memberships_user ON public.workspace_memberships(user_id);

CREATE INDEX IF NOT EXISTS idx_dashboards_workspace ON public.dashboards(workspace_id);
CREATE INDEX IF NOT EXISTS idx_widgets_dashboard ON public.widgets(dashboard_id);

CREATE INDEX IF NOT EXISTS idx_sources_workspace ON public.ingestion_sources(workspace_id);
CREATE INDEX IF NOT EXISTS idx_events_workspace_time ON public.events(workspace_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_source_time ON public.events(source_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_workspace_time ON public.audit_logs(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_org_time ON public.audit_logs(organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_actor_time ON public.audit_logs(actor_user_id, created_at DESC);

-- Record this migration version (idempotent)
INSERT INTO public.schema_migrations(version)
VALUES ('2026-03-09_init_schema')
ON CONFLICT (version) DO NOTHING;

COMMIT;
SQL

echo "✅ Migrations complete"
