#!/bin/bash
set -euo pipefail

# Seed script for the enterprise analytics platform database.
# Uses db_connection.txt as the authoritative connection string, aligning with startup.sh.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

if [ ! -f "db_connection.txt" ]; then
  echo "❌ db_connection.txt not found. Run startup.sh first."
  exit 1
fi

PSQL_CMD="$(cat db_connection.txt)"
echo "Seeding data using: ${PSQL_CMD}"

${PSQL_CMD} <<'SQL'
BEGIN;

-- Create a default org + workspace
INSERT INTO public.organizations (slug, name)
VALUES ('acme', 'Acme Analytics')
ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO public.workspaces (organization_id, slug, name)
SELECT o.id, 'default', 'Default Workspace'
FROM public.organizations o
WHERE o.slug = 'acme'
ON CONFLICT (organization_id, slug) DO UPDATE SET name = EXCLUDED.name;

-- Create a couple of users
INSERT INTO public.users (email, full_name, is_superadmin)
VALUES
  ('admin@acme.test', 'Acme Admin', TRUE),
  ('analyst@acme.test', 'Acme Analyst', FALSE)
ON CONFLICT (email) DO UPDATE SET
  full_name = EXCLUDED.full_name;

-- Permissions catalog (minimal, extensible)
INSERT INTO public.permissions (code, description) VALUES
  ('orgs:read', 'Read organizations'),
  ('orgs:write', 'Manage organizations'),
  ('workspaces:read', 'Read workspaces'),
  ('workspaces:write', 'Manage workspaces'),
  ('dashboards:read', 'Read dashboards'),
  ('dashboards:write', 'Create/update dashboards'),
  ('widgets:read', 'Read widgets'),
  ('widgets:write', 'Create/update widgets'),
  ('ingestion:read', 'Read ingestion sources and events'),
  ('ingestion:write', 'Manage ingestion sources'),
  ('audit:read', 'Read audit logs')
ON CONFLICT (code) DO NOTHING;

-- Create org-scoped roles
WITH org AS (
  SELECT id FROM public.organizations WHERE slug = 'acme'
)
INSERT INTO public.roles (organization_id, name, description)
SELECT org.id, r.name, r.description
FROM org
CROSS JOIN (VALUES
  ('Owner', 'Full control within the organization'),
  ('Admin', 'Administrative access'),
  ('Analyst', 'Can view dashboards and data'),
  ('Viewer', 'Read-only access')
) AS r(name, description)
ON CONFLICT (organization_id, name) DO NOTHING;

-- Attach permissions to roles
-- Owner/Admin: all permissions
WITH org AS (
  SELECT id FROM public.organizations WHERE slug = 'acme'
),
role_ids AS (
  SELECT r.id, r.name
  FROM public.roles r
  JOIN org ON r.organization_id = org.id
  WHERE r.name IN ('Owner','Admin')
),
perm_ids AS (
  SELECT id FROM public.permissions
)
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT role_ids.id, perm_ids.id
FROM role_ids CROSS JOIN perm_ids
ON CONFLICT DO NOTHING;

-- Analyst: read dashboards/widgets/ingestion/audit + write dashboards/widgets
WITH org AS (
  SELECT id FROM public.organizations WHERE slug = 'acme'
),
analyst_role AS (
  SELECT r.id
  FROM public.roles r
  JOIN org ON r.organization_id = org.id
  WHERE r.name = 'Analyst'
),
perms AS (
  SELECT id FROM public.permissions WHERE code IN (
    'workspaces:read',
    'dashboards:read','dashboards:write',
    'widgets:read','widgets:write',
    'ingestion:read',
    'audit:read'
  )
)
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT (SELECT id FROM analyst_role), perms.id
FROM perms
ON CONFLICT DO NOTHING;

-- Viewer: read-only dashboards/widgets
WITH org AS (
  SELECT id FROM public.organizations WHERE slug = 'acme'
),
viewer_role AS (
  SELECT r.id
  FROM public.roles r
  JOIN org ON r.organization_id = org.id
  WHERE r.name = 'Viewer'
),
perms AS (
  SELECT id FROM public.permissions WHERE code IN (
    'workspaces:read',
    'dashboards:read',
    'widgets:read',
    'ingestion:read',
    'audit:read'
  )
)
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT (SELECT id FROM viewer_role), perms.id
FROM perms
ON CONFLICT DO NOTHING;

-- Add workspace membership for users
WITH ws AS (
  SELECT w.id AS workspace_id, w.organization_id
  FROM public.workspaces w
  JOIN public.organizations o ON o.id = w.organization_id
  WHERE o.slug = 'acme' AND w.slug = 'default'
),
u_admin AS (
  SELECT id AS user_id FROM public.users WHERE email = 'admin@acme.test'
),
u_analyst AS (
  SELECT id AS user_id FROM public.users WHERE email = 'analyst@acme.test'
),
r_owner AS (
  SELECT r.id AS role_id
  FROM public.roles r
  JOIN ws ON r.organization_id = ws.organization_id
  WHERE r.name = 'Owner'
),
r_analyst AS (
  SELECT r.id AS role_id
  FROM public.roles r
  JOIN ws ON r.organization_id = ws.organization_id
  WHERE r.name = 'Analyst'
)
INSERT INTO public.workspace_memberships (workspace_id, user_id, role_id)
SELECT (SELECT workspace_id FROM ws), (SELECT user_id FROM u_admin), (SELECT role_id FROM r_owner)
ON CONFLICT (workspace_id, user_id) DO UPDATE SET role_id = EXCLUDED.role_id;

WITH ws AS (
  SELECT w.id AS workspace_id, w.organization_id
  FROM public.workspaces w
  JOIN public.organizations o ON o.id = w.organization_id
  WHERE o.slug = 'acme' AND w.slug = 'default'
),
u_analyst AS (
  SELECT id AS user_id FROM public.users WHERE email = 'analyst@acme.test'
),
r_analyst AS (
  SELECT r.id AS role_id
  FROM public.roles r
  JOIN ws ON r.organization_id = ws.organization_id
  WHERE r.name = 'Analyst'
)
INSERT INTO public.workspace_memberships (workspace_id, user_id, role_id)
SELECT (SELECT workspace_id FROM ws), (SELECT user_id FROM u_analyst), (SELECT role_id FROM r_analyst)
ON CONFLICT (workspace_id, user_id) DO UPDATE SET role_id = EXCLUDED.role_id;

-- Sample dashboard + widgets
WITH ws AS (
  SELECT w.id AS workspace_id
  FROM public.workspaces w
  JOIN public.organizations o ON o.id = w.organization_id
  WHERE o.slug = 'acme' AND w.slug = 'default'
),
creator AS (
  SELECT id AS user_id FROM public.users WHERE email = 'admin@acme.test'
)
INSERT INTO public.dashboards (workspace_id, name, description, layout, filters, is_shared, created_by)
SELECT
  (SELECT workspace_id FROM ws),
  'Executive Overview',
  'Seeded example dashboard for demo and smoke-testing',
  '{"columns":12,"rowHeight":24}'::jsonb,
  '{"timeRange":"last_7_days"}'::jsonb,
  TRUE,
  (SELECT user_id FROM creator)
WHERE NOT EXISTS (
  SELECT 1 FROM public.dashboards d
  WHERE d.workspace_id = (SELECT workspace_id FROM ws) AND d.name = 'Executive Overview'
);

-- Insert a few widgets only if missing
WITH dash AS (
  SELECT d.id AS dashboard_id
  FROM public.dashboards d
  JOIN public.workspaces w ON w.id = d.workspace_id
  JOIN public.organizations o ON o.id = w.organization_id
  WHERE o.slug = 'acme' AND w.slug = 'default' AND d.name = 'Executive Overview'
)
INSERT INTO public.widgets (dashboard_id, type, title, query, config, position, refresh_interval_seconds)
SELECT
  (SELECT dashboard_id FROM dash),
  'metric'::public.widget_type,
  'Total Events (7d)',
  '{"metric":"events.count","groupBy":[]}'::jsonb,
  '{"format":"number"}'::jsonb,
  '{"x":0,"y":0,"w":3,"h":3}'::jsonb,
  60
WHERE NOT EXISTS (
  SELECT 1 FROM public.widgets w
  WHERE w.dashboard_id = (SELECT dashboard_id FROM dash) AND w.title = 'Total Events (7d)'
);

WITH dash AS (
  SELECT d.id AS dashboard_id
  FROM public.dashboards d
  JOIN public.workspaces w ON w.id = d.workspace_id
  JOIN public.organizations o ON o.id = w.organization_id
  WHERE o.slug = 'acme' AND w.slug = 'default' AND d.name = 'Executive Overview'
)
INSERT INTO public.widgets (dashboard_id, type, title, query, config, position, refresh_interval_seconds)
SELECT
  (SELECT dashboard_id FROM dash),
  'line'::public.widget_type,
  'Events Over Time',
  '{"metric":"events.count","groupBy":["day"]}'::jsonb,
  '{"xAxis":"day","yAxis":"count"}'::jsonb,
  '{"x":3,"y":0,"w":9,"h":6}'::jsonb,
  60
WHERE NOT EXISTS (
  SELECT 1 FROM public.widgets w
  WHERE w.dashboard_id = (SELECT dashboard_id FROM dash) AND w.title = 'Events Over Time'
);

WITH dash AS (
  SELECT d.id AS dashboard_id
  FROM public.dashboards d
  JOIN public.workspaces w ON w.id = d.workspace_id
  JOIN public.organizations o ON o.id = w.organization_id
  WHERE o.slug = 'acme' AND w.slug = 'default' AND d.name = 'Executive Overview'
)
INSERT INTO public.widgets (dashboard_id, type, title, query, config, position, refresh_interval_seconds)
SELECT
  (SELECT dashboard_id FROM dash),
  'table'::public.widget_type,
  'Recent Events',
  '{"source":"events","columns":["occurred_at","event_name","status"]}'::jsonb,
  '{"pageSize":10}'::jsonb,
  '{"x":0,"y":6,"w":12,"h":6}'::jsonb,
  30
WHERE NOT EXISTS (
  SELECT 1 FROM public.widgets w
  WHERE w.dashboard_id = (SELECT dashboard_id FROM dash) AND w.title = 'Recent Events'
);

-- Ingestion source + sample events
WITH ws AS (
  SELECT w.id AS workspace_id
  FROM public.workspaces w
  JOIN public.organizations o ON o.id = w.organization_id
  WHERE o.slug = 'acme' AND w.slug = 'default'
)
INSERT INTO public.ingestion_sources (workspace_id, name, description, kind, config)
SELECT
  (SELECT workspace_id FROM ws),
  'Demo HTTP Ingestion',
  'Seeded ingestion source for local testing',
  'http',
  '{"auth":"none","path":"/ingest"}'::jsonb
ON CONFLICT (workspace_id, name) DO UPDATE SET
  description = EXCLUDED.description,
  config = EXCLUDED.config,
  is_active = TRUE;

-- Insert events if table is empty for this workspace (keep seed small)
WITH ws AS (
  SELECT w.id AS workspace_id
  FROM public.workspaces w
  JOIN public.organizations o ON o.id = w.organization_id
  WHERE o.slug = 'acme' AND w.slug = 'default'
),
src AS (
  SELECT s.id AS source_id
  FROM public.ingestion_sources s
  WHERE s.workspace_id = (SELECT workspace_id FROM ws) AND s.name = 'Demo HTTP Ingestion'
)
INSERT INTO public.events (workspace_id, source_id, event_name, occurred_at, status, payload)
SELECT
  (SELECT workspace_id FROM ws),
  (SELECT source_id FROM src),
  e.event_name,
  now() - e.offset,
  'processed'::public.event_status,
  jsonb_build_object('demo', true, 'value', e.value, 'tags', jsonb_build_array('seed','acme'))
FROM (VALUES
  ('page_view', interval '10 minutes', 1),
  ('page_view', interval '9 minutes', 1),
  ('signup', interval '8 minutes', 1),
  ('purchase', interval '7 minutes', 99),
  ('page_view', interval '6 minutes', 1)
) AS e(event_name, offset, value)
WHERE NOT EXISTS (
  SELECT 1 FROM public.events ev
  WHERE ev.workspace_id = (SELECT workspace_id FROM ws)
);

-- Audit log entry for seed (idempotent-ish: avoid duplicates by checking for same action/entity_type)
WITH org AS (
  SELECT id FROM public.organizations WHERE slug = 'acme'
),
ws AS (
  SELECT w.id AS workspace_id
  FROM public.workspaces w
  JOIN org ON w.organization_id = org.id
  WHERE w.slug = 'default'
),
actor AS (
  SELECT id AS actor_user_id FROM public.users WHERE email = 'admin@acme.test'
)
INSERT INTO public.audit_logs (workspace_id, organization_id, actor_user_id, action, entity_type, metadata)
SELECT
  (SELECT workspace_id FROM ws),
  (SELECT id FROM org),
  (SELECT actor_user_id FROM actor),
  'create'::public.audit_action,
  'seed',
  '{"note":"Initial seed applied"}'::jsonb
WHERE NOT EXISTS (
  SELECT 1 FROM public.audit_logs a
  WHERE a.organization_id = (SELECT id FROM org)
    AND a.entity_type = 'seed'
);

COMMIT;
SQL

echo "✅ Seed complete"
