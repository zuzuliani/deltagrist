# Multi-Tenant Grist Implementation Plan

**Architecture:** "Supabase Points, Grist Delivers"  
**Created:** 2025-11-24  
**Status:** Planning Phase

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [System Components](#system-components)
3. [Database Schema](#database-schema)
4. [Grist Configuration](#grist-configuration)
5. [Railway Backend API](#railway-backend-api)
6. [Authentication Flow](#authentication-flow)
7. [Document Lifecycle](#document-lifecycle)
8. [Permission Management](#permission-management)
9. [WeWeb Integration](#weweb-integration)
10. [Deployment Steps](#deployment-steps)
11. [Testing Strategy](#testing-strategy)
12. [Monitoring & Maintenance](#monitoring--maintenance)
13. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

### High-Level Design

```
┌─────────────────────────────────────────────────────────────┐
│                         WeWeb SaaS                          │
│                    (Multi-tenant Frontend)                   │
└────────────┬────────────────────────────────┬───────────────┘
             │                                │
             │ Auth/Data                      │ Grist Embed
             ↓                                ↓
┌────────────────────────┐        ┌──────────────────────────┐
│      Supabase          │        │   Railway Backend        │
│  ┌──────────────────┐  │        │  ┌────────────────────┐  │
│  │ PostgreSQL       │  │←───────┤  │ Orchestration API  │  │
│  │ - tenants        │  │        │  │ - Auth middleware  │  │
│  │ - users          │  │        │  │ - Grist API client │  │
│  │ - projects       │  │        │  │ - Permission sync  │  │
│  │ - grist_docs     │  │        │  └────────┬───────────┘  │
│  │ - permissions    │  │        │           │              │
│  └──────────────────┘  │        └───────────┼──────────────┘
│                        │                    │
│  ┌──────────────────┐  │                    │
│  │ Storage (backup) │  │                    │
│  │ - .grist files   │  │                    ↓
│  │   (optional)     │  │        ┌──────────────────────────┐
│  └──────────────────┘  │        │   Grist Docker           │
└────────────────────────┘        │   (Railway Deploy)       │
                                  │  ┌────────────────────┐  │
                                  │  │ Home Server        │  │
                                  │  │ - User mgmt        │  │
                                  │  │ - API endpoints    │  │
                                  │  └────────────────────┘  │
                                  │  ┌────────────────────┐  │
                                  │  │ Doc Workers        │  │
                                  │  │ - SQLite docs      │  │
                                  │  │ - Python engine    │  │
                                  │  │ - Real-time sync   │  │
                                  │  └────────────────────┘  │
                                  │  ┌────────────────────┐  │
                                  │  │ Persistent Volume  │  │
                                  │  │ /persist/docs      │  │
                                  │  │ /persist/home.db   │  │
                                  │  └────────────────────┘  │
                                  └──────────────────────────┘
```

### Core Principles

1. **Grist manages active documents** - All live spreadsheet data, formulas, and real-time collaboration
2. **Supabase stores metadata** - Tenant mappings, user permissions, document pointers
3. **Railway Backend orchestrates** - Creates docs, syncs permissions, proxies requests
4. **WeWeb embeds Grist** - iFrame integration with SSO-style authentication

---

## System Components

### 1. Supabase (Source of Truth)
**Purpose:** Multi-tenant database and metadata store

**Responsibilities:**
- User authentication (Supabase Auth)
- Tenant data isolation (Row Level Security)
- Project → Grist document mapping
- User permission mappings
- Audit logging

### 2. Grist Docker (Document Engine)
**Purpose:** Spreadsheet storage, computation, and real-time collaboration

**Responsibilities:**
- Store .grist files (SQLite)
- Execute formulas (Python sandbox)
- Real-time WebSocket connections
- Document versioning & undo/redo
- Fine-grained ACL enforcement

### 3. Railway Backend (Orchestrator)
**Purpose:** Bridge between Supabase and Grist

**Responsibilities:**
- Authenticate WeWeb users
- Create Grist organizations/workspaces
- Create and manage documents
- Sync permissions bidirectionally
- Proxy authenticated requests to Grist
- Handle webhooks from Grist (optional)

### 4. WeWeb Frontend
**Purpose:** User interface for your SaaS

**Responsibilities:**
- Display project list
- Embed Grist documents (iFrame)
- Trigger document creation
- Manage project permissions (UI)

---

## Database Schema

### Supabase Tables

#### `tenants`
```sql
CREATE TABLE tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  grist_org_id INTEGER, -- Grist organization ID (if using org-per-tenant)
  grist_workspace_id INTEGER, -- Grist workspace ID (if using workspace-per-tenant)
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- RLS Policies
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own tenant"
  ON tenants FOR SELECT
  USING (auth.uid() IN (
    SELECT user_id FROM tenant_users WHERE tenant_id = tenants.id
  ));
```

#### `tenant_users`
```sql
CREATE TABLE tenant_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(tenant_id, user_id)
);

-- RLS Policies
ALTER TABLE tenant_users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their tenant memberships"
  ON tenant_users FOR SELECT
  USING (auth.uid() = user_id);
```

#### `projects`
```sql
CREATE TABLE projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  
  -- Grist document identifiers
  grist_doc_id TEXT UNIQUE NOT NULL, -- Main document ID (e.g., "keLK5sVeyfPkxyaXqijz2x")
  grist_url_id TEXT, -- URL-friendly ID (optional)
  grist_workspace_id INTEGER NOT NULL, -- Workspace containing this doc
  
  -- Metadata
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  archived_at TIMESTAMPTZ, -- Soft delete
  
  -- Searchable fields
  search_vector TSVECTOR GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, ''))
  ) STORED
);

-- Indexes
CREATE INDEX idx_projects_tenant ON projects(tenant_id);
CREATE INDEX idx_projects_grist_doc ON projects(grist_doc_id);
CREATE INDEX idx_projects_search ON projects USING GIN(search_vector);

-- RLS Policies
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view projects in their tenant"
  ON projects FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_users WHERE user_id = auth.uid()
    )
    AND archived_at IS NULL
  );

CREATE POLICY "Admins can insert projects"
  ON projects FOR INSERT
  WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM tenant_users 
      WHERE user_id = auth.uid() 
      AND role IN ('owner', 'admin')
    )
  );

CREATE POLICY "Admins can update projects"
  ON projects FOR UPDATE
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_users 
      WHERE user_id = auth.uid() 
      AND role IN ('owner', 'admin')
    )
  );
```

#### `project_users`
```sql
CREATE TABLE project_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID REFERENCES projects(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  
  -- Grist role mapping
  -- 'owners' = full access + ACL editing
  -- 'editors' = can edit data
  -- 'viewers' = read-only
  grist_role TEXT NOT NULL CHECK (grist_role IN ('owners', 'editors', 'viewers')),
  
  granted_by UUID REFERENCES auth.users(id),
  granted_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(project_id, user_id)
);

-- RLS Policies
ALTER TABLE project_users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view project memberships they have access to"
  ON project_users FOR SELECT
  USING (
    project_id IN (
      SELECT id FROM projects WHERE tenant_id IN (
        SELECT tenant_id FROM tenant_users WHERE user_id = auth.uid()
      )
    )
  );
```

#### `grist_sync_log`
```sql
-- Track synchronization between Supabase and Grist
CREATE TABLE grist_sync_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type TEXT NOT NULL CHECK (entity_type IN ('workspace', 'document', 'user_access')),
  entity_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('create', 'update', 'delete')),
  status TEXT NOT NULL CHECK (status IN ('pending', 'success', 'failed')),
  request_payload JSONB,
  response_payload JSONB,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ
);

CREATE INDEX idx_sync_log_status ON grist_sync_log(status, created_at);
CREATE INDEX idx_sync_log_entity ON grist_sync_log(entity_type, entity_id);
```

### Database Functions

#### `get_user_grist_role(project_id, user_id)`
```sql
CREATE OR REPLACE FUNCTION get_user_grist_role(
  p_project_id UUID,
  p_user_id UUID
)
RETURNS TEXT AS $$
DECLARE
  v_role TEXT;
  v_tenant_role TEXT;
BEGIN
  -- Check project-specific role
  SELECT grist_role INTO v_role
  FROM project_users
  WHERE project_id = p_project_id AND user_id = p_user_id;
  
  IF v_role IS NOT NULL THEN
    RETURN v_role;
  END IF;
  
  -- Check tenant-level role
  SELECT role INTO v_tenant_role
  FROM tenant_users tu
  JOIN projects p ON p.tenant_id = tu.tenant_id
  WHERE p.id = p_project_id AND tu.user_id = p_user_id;
  
  -- Map tenant roles to Grist roles
  RETURN CASE
    WHEN v_tenant_role IN ('owner', 'admin') THEN 'editors'
    WHEN v_tenant_role = 'member' THEN 'viewers'
    ELSE NULL
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## Grist Configuration

### Docker Deployment (Railway)

#### `railway.toml`
```toml
[build]
builder = "DOCKERFILE"
dockerfilePath = "./Dockerfile"

[deploy]
startCommand = "node ./sandbox/supervisor.mjs"
restartPolicyType = "ON_FAILURE"
restartPolicyMaxRetries = 3
```

#### Environment Variables

```bash
# ============================================
# Required Configuration
# ============================================

# Server Configuration
GRIST_HOST=0.0.0.0
PORT=8484
GRIST_SINGLE_PORT=true
GRIST_SERVE_SAME_ORIGIN=true

# Organization
GRIST_ORG_IN_PATH=true
GRIST_SINGLE_ORG=your-saas-name  # Single org for all tenants (recommended)

# Data Persistence
GRIST_DATA_DIR=/persist/docs
GRIST_INST_DIR=/persist

# Database (SQLite or PostgreSQL for HomeDB)
TYPEORM_TYPE=postgres
TYPEORM_HOST=${RAILWAY_POSTGRES_HOST}
TYPEORM_PORT=${RAILWAY_POSTGRES_PORT}
TYPEORM_DATABASE=${RAILWAY_POSTGRES_DATABASE}
TYPEORM_USERNAME=${RAILWAY_POSTGRES_USER}
TYPEORM_PASSWORD=${RAILWAY_POSTGRES_PASSWORD}
# OR for SQLite:
# TYPEORM_TYPE=sqlite
# TYPEORM_DATABASE=/persist/home.sqlite3

# ============================================
# Authentication
# ============================================

# Forward Auth (recommended for your use case)
GRIST_FORWARD_AUTH_HEADER=X-Forwarded-User
GRIST_FORWARD_AUTH_LOGIN_PATH=/auth/login
GRIST_FORWARD_AUTH_LOGOUT_PATH=/auth/logout
GRIST_IGNORE_SESSION=false  # Keep sessions enabled

# Force authentication
GRIST_FORCE_LOGIN=true
GRIST_ANON_PLAYGROUND=false

# ============================================
# Security
# ============================================

# Session
GRIST_SESSION_SECRET=${GRIST_SESSION_SECRET}  # Generate: openssl rand -hex 32
GRIST_SESSION_COOKIE=grist_sid

# Webhook domains (if using webhooks)
ALLOWED_WEBHOOK_DOMAINS=your-backend.railway.app,hooks.zapier.com

# ============================================
# External Storage (Optional but Recommended)
# ============================================

# S3-compatible storage (Supabase Storage)
GRIST_DOCS_S3_BUCKET=grist-documents
GRIST_DOCS_S3_PREFIX=docs/
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=${SUPABASE_S3_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${SUPABASE_S3_SECRET_KEY}
AWS_S3_ENDPOINT=https://${SUPABASE_PROJECT_ID}.supabase.co/storage/v1/s3

# Snapshots (backups)
GRIST_SNAPSHOT_KEEP=10
GRIST_BACKUP_DELAY_SECS=60

# ============================================
# Performance & Limits
# ============================================

GRIST_MAX_UPLOAD_IMPORT_MB=50
GRIST_MAX_UPLOAD_ATTACHMENT_MB=50
GRIST_MAX_PARALLEL_REQUESTS_PER_DOC=10

# ============================================
# Features
# ============================================

GRIST_HIDE_UI_ELEMENTS=billing,templates,tutorials,supportGrist
GRIST_UI_FEATURES=  # Leave empty to hide non-essential features

# Sandboxing
GRIST_SANDBOX_FLAVOR=unsandboxed  # Or 'gvisor' if Railway supports it

# Telemetry
GRIST_TELEMETRY_LEVEL=off

# ============================================
# Development/Debugging
# ============================================

NODE_ENV=production
# GRIST_LOG_LEVEL=info
# TYPEORM_LOGGING=false
```

### Grist HomeDB Schema

Grist will automatically create its own tables:
- `orgs` - Organizations
- `workspaces` - Workspaces within orgs
- `docs` - Document metadata
- `users` - User accounts
- `groups` - Permission groups (owners, editors, viewers)
- `group_users` - User-to-group mappings
- `acl_rules` - Access control rules

**Note:** You don't manage these directly. Use the Grist API instead.

---

## Railway Backend API

### Technology Stack

**Recommended:**
- Node.js + Express (or Fastify)
- TypeScript
- Supabase JS client
- Axios (for Grist API calls)

### Project Structure

```
railway-backend/
├── src/
│   ├── config/
│   │   ├── supabase.ts       # Supabase client
│   │   └── grist.ts          # Grist API client
│   ├── middleware/
│   │   ├── auth.ts           # Verify Supabase JWT
│   │   ├── tenant.ts         # Extract tenant context
│   │   └── grist-proxy.ts    # Forward auth headers
│   ├── routes/
│   │   ├── projects.ts       # Project CRUD
│   │   ├── grist-proxy.ts    # Proxy to Grist
│   │   └── webhooks.ts       # Grist webhooks
│   ├── services/
│   │   ├── grist.service.ts  # Grist API wrapper
│   │   ├── tenant.service.ts # Tenant operations
│   │   └── sync.service.ts   # Permission sync
│   └── index.ts
├── package.json
└── tsconfig.json
```

### Core API Endpoints

#### 1. Project Management

```typescript
// POST /api/projects
// Create new project (creates Grist document)
interface CreateProjectRequest {
  name: string;
  description?: string;
  templateId?: string; // Grist doc ID to copy from
}

interface CreateProjectResponse {
  projectId: string;
  gristDocId: string;
  gristUrl: string;
}
```

```typescript
// GET /api/projects
// List all projects for current tenant
interface ListProjectsResponse {
  projects: Array<{
    id: string;
    name: string;
    description: string;
    gristDocId: string;
    createdAt: string;
    updatedAt: string;
  }>;
}
```

```typescript
// GET /api/projects/:projectId
// Get project details
interface GetProjectResponse {
  project: {
    id: string;
    name: string;
    description: string;
    gristDocId: string;
    gristUrl: string;
    permissions: Array<{
      userId: string;
      email: string;
      role: 'owners' | 'editors' | 'viewers';
    }>;
  };
}
```

```typescript
// DELETE /api/projects/:projectId
// Archive project (soft delete in Supabase, remove from Grist)
```

#### 2. Permission Management

```typescript
// POST /api/projects/:projectId/users
// Grant user access to project
interface GrantAccessRequest {
  email: string;
  role: 'owners' | 'editors' | 'viewers';
}

// DELETE /api/projects/:projectId/users/:userId
// Revoke user access
```

#### 3. Grist Proxy

```typescript
// GET /api/grist/:projectId/*
// Proxy authenticated requests to Grist
// Adds X-Forwarded-User header with user's email
// Maps :projectId to gristDocId

// Example:
// GET /api/grist/abc-123/tables/TableName/records
// → GET https://grist.railway.app/api/docs/{gristDocId}/tables/TableName/records
//   (with X-Forwarded-User: user@example.com)
```

### Implementation Example

#### `src/services/grist.service.ts`

```typescript
import axios, { AxiosInstance } from 'axios';

export class GristService {
  private client: AxiosInstance;
  private baseUrl: string;
  private apiKey: string;

  constructor() {
    this.baseUrl = process.env.GRIST_URL!;
    this.apiKey = process.env.GRIST_API_KEY!;
    
    this.client = axios.create({
      baseURL: this.baseUrl,
      headers: {
        'Authorization': `Bearer ${this.apiKey}`,
        'Content-Type': 'application/json',
      },
    });
  }

  /**
   * Create a new organization
   */
  async createOrganization(name: string, domain: string) {
    const response = await this.client.post('/api/orgs', {
      name,
      domain,
    });
    return response.data;
  }

  /**
   * Create a workspace within an organization
   */
  async createWorkspace(orgId: number, name: string) {
    const response = await this.client.post(`/api/orgs/${orgId}/workspaces`, {
      name,
    });
    return response.data;
  }

  /**
   * Create a document within a workspace
   */
  async createDocument(
    workspaceId: number,
    name: string,
    options?: {
      sourceDocumentId?: string; // Template to copy from
    }
  ) {
    const response = await this.client.post('/api/docs', {
      workspaceId,
      documentName: name,
      sourceDocumentId: options?.sourceDocumentId,
    });
    return response.data;
  }

  /**
   * Grant user access to a document
   */
  async grantDocumentAccess(
    docId: string,
    userEmail: string,
    role: 'owners' | 'editors' | 'viewers'
  ) {
    const response = await this.client.patch(`/api/docs/${docId}/access`, {
      delta: {
        users: {
          [userEmail]: role,
        },
      },
    });
    return response.data;
  }

  /**
   * Revoke user access to a document
   */
  async revokeDocumentAccess(docId: string, userEmail: string) {
    const response = await this.client.patch(`/api/docs/${docId}/access`, {
      delta: {
        users: {
          [userEmail]: null, // null = remove access
        },
      },
    });
    return response.data;
  }

  /**
   * Get document metadata
   */
  async getDocument(docId: string) {
    const response = await this.client.get(`/api/docs/${docId}`);
    return response.data;
  }

  /**
   * Delete document
   */
  async deleteDocument(docId: string) {
    const response = await this.client.delete(`/api/docs/${docId}`);
    return response.data;
  }

  /**
   * Get document access list
   */
  async getDocumentAccess(docId: string) {
    const response = await this.client.get(`/api/docs/${docId}/access`);
    return response.data;
  }

  /**
   * Download document (.grist file)
   */
  async downloadDocument(docId: string): Promise<Buffer> {
    const response = await this.client.get(`/api/docs/${docId}/download`, {
      responseType: 'arraybuffer',
    });
    return Buffer.from(response.data);
  }

  /**
   * Proxy request to Grist with user context
   */
  async proxyRequest(
    method: string,
    path: string,
    userEmail: string,
    data?: any
  ) {
    const response = await this.client.request({
      method,
      url: path,
      data,
      headers: {
        'X-Forwarded-User': userEmail,
      },
    });
    return response.data;
  }
}
```

#### `src/routes/projects.ts`

```typescript
import { Router } from 'express';
import { GristService } from '../services/grist.service';
import { supabase } from '../config/supabase';
import { requireAuth, requireTenant } from '../middleware/auth';

const router = Router();
const gristService = new GristService();

/**
 * POST /api/projects
 * Create new project
 */
router.post('/', requireAuth, requireTenant, async (req, res) => {
  const { name, description, templateId } = req.body;
  const { user, tenant } = req;

  try {
    // 1. Get or create workspace for tenant
    let workspaceId = tenant.grist_workspace_id;
    
    if (!workspaceId) {
      // Create workspace for this tenant
      const workspace = await gristService.createWorkspace(
        tenant.grist_org_id,
        `Tenant: ${tenant.name}`
      );
      workspaceId = workspace.id;
      
      // Update tenant with workspace ID
      await supabase
        .from('tenants')
        .update({ grist_workspace_id: workspaceId })
        .eq('id', tenant.id);
    }

    // 2. Create document in Grist
    const gristDoc = await gristService.createDocument(
      workspaceId,
      name,
      { sourceDocumentId: templateId }
    );

    // 3. Grant creator access
    await gristService.grantDocumentAccess(
      gristDoc.id,
      user.email,
      'owners'
    );

    // 4. Store in Supabase
    const { data: project, error } = await supabase
      .from('projects')
      .insert({
        tenant_id: tenant.id,
        name,
        description,
        grist_doc_id: gristDoc.id,
        grist_url_id: gristDoc.urlId,
        grist_workspace_id: workspaceId,
        created_by: user.id,
      })
      .select()
      .single();

    if (error) throw error;

    // 5. Log sync
    await supabase.from('grist_sync_log').insert({
      entity_type: 'document',
      entity_id: gristDoc.id,
      action: 'create',
      status: 'success',
      request_payload: { name, workspaceId },
      response_payload: gristDoc,
    });

    res.status(201).json({
      project: {
        id: project.id,
        name: project.name,
        gristDocId: project.grist_doc_id,
        gristUrl: `${process.env.GRIST_URL}/o/docs/doc/${project.grist_url_id || project.grist_doc_id}`,
      },
    });
  } catch (error) {
    console.error('Error creating project:', error);
    
    // Log failed sync
    await supabase.from('grist_sync_log').insert({
      entity_type: 'document',
      entity_id: 'unknown',
      action: 'create',
      status: 'failed',
      error_message: error.message,
    });
    
    res.status(500).json({ error: 'Failed to create project' });
  }
});

/**
 * GET /api/projects
 * List projects for tenant
 */
router.get('/', requireAuth, requireTenant, async (req, res) => {
  const { tenant } = req;

  const { data: projects, error } = await supabase
    .from('projects')
    .select('*')
    .eq('tenant_id', tenant.id)
    .is('archived_at', null)
    .order('created_at', { ascending: false });

  if (error) {
    return res.status(500).json({ error: 'Failed to fetch projects' });
  }

  res.json({ projects });
});

/**
 * POST /api/projects/:projectId/users
 * Grant user access
 */
router.post('/:projectId/users', requireAuth, requireTenant, async (req, res) => {
  const { projectId } = req.params;
  const { email, role } = req.body;
  const { user, tenant } = req;

  try {
    // 1. Verify project belongs to tenant
    const { data: project } = await supabase
      .from('projects')
      .select('*')
      .eq('id', projectId)
      .eq('tenant_id', tenant.id)
      .single();

    if (!project) {
      return res.status(404).json({ error: 'Project not found' });
    }

    // 2. Find or invite user
    const { data: targetUser } = await supabase
      .from('auth.users')
      .select('id')
      .eq('email', email)
      .single();

    if (!targetUser) {
      return res.status(404).json({ error: 'User not found' });
    }

    // 3. Grant in Grist
    await gristService.grantDocumentAccess(
      project.grist_doc_id,
      email,
      role
    );

    // 4. Store in Supabase
    const { error } = await supabase
      .from('project_users')
      .insert({
        project_id: projectId,
        user_id: targetUser.id,
        grist_role: role,
        granted_by: user.id,
      });

    if (error && error.code !== '23505') { // Ignore duplicate
      throw error;
    }

    res.status(201).json({ success: true });
  } catch (error) {
    console.error('Error granting access:', error);
    res.status(500).json({ error: 'Failed to grant access' });
  }
});

export default router;
```

#### `src/middleware/auth.ts`

```typescript
import { Request, Response, NextFunction } from 'express';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_KEY! // Service role key
);

export interface AuthRequest extends Request {
  user?: any;
  tenant?: any;
}

/**
 * Verify Supabase JWT token
 */
export async function requireAuth(
  req: AuthRequest,
  res: Response,
  next: NextFunction
) {
  const authHeader = req.headers.authorization;
  
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const token = authHeader.split(' ')[1];

  try {
    const { data: { user }, error } = await supabase.auth.getUser(token);
    
    if (error || !user) {
      return res.status(401).json({ error: 'Invalid token' });
    }

    req.user = user;
    next();
  } catch (error) {
    res.status(401).json({ error: 'Unauthorized' });
  }
}

/**
 * Extract tenant from request
 */
export async function requireTenant(
  req: AuthRequest,
  res: Response,
  next: NextFunction
) {
  const tenantId = req.headers['x-tenant-id'] || req.query.tenantId;
  
  if (!tenantId) {
    return res.status(400).json({ error: 'Tenant ID required' });
  }

  // Verify user belongs to tenant
  const { data: membership } = await supabase
    .from('tenant_users')
    .select('*, tenants(*)')
    .eq('tenant_id', tenantId)
    .eq('user_id', req.user.id)
    .single();

  if (!membership) {
    return res.status(403).json({ error: 'Access denied' });
  }

  req.tenant = membership.tenants;
  next();
}
```

---

## Authentication Flow

### User Login Sequence

```
1. User logs in via WeWeb
   ↓
2. Supabase Auth issues JWT
   ↓
3. WeWeb stores JWT + user info
   ↓
4. User navigates to project
   ↓
5. WeWeb calls Railway Backend with JWT
   ↓
6. Backend verifies JWT with Supabase
   ↓
7. Backend proxies to Grist with X-Forwarded-User header
   ↓
8. Grist trusts header, grants access
   ↓
9. User sees embedded Grist document
```

### Grist iFrame Embedding

```html
<!-- In WeWeb -->
<iframe
  src="https://your-backend.railway.app/api/grist/{projectId}/embed"
  width="100%"
  height="800px"
  frameborder="0"
  allow="clipboard-read; clipboard-write"
></iframe>
```

#### Backend Embed Endpoint

```typescript
// src/routes/grist-proxy.ts

router.get('/grist/:projectId/embed', requireAuth, async (req, res) => {
  const { projectId } = req.params;
  const { user } = req;

  // Get project and verify access
  const { data: project } = await supabase
    .from('projects')
    .select('grist_doc_id, grist_url_id')
    .eq('id', projectId)
    .single();

  if (!project) {
    return res.status(404).send('Project not found');
  }

  // Check user has access
  const role = await getUserGristRole(projectId, user.id);
  if (!role) {
    return res.status(403).send('Access denied');
  }

  // Redirect to Grist with auth
  const gristUrl = `${process.env.GRIST_URL}/o/docs/doc/${project.grist_url_id || project.grist_doc_id}`;
  
  // Set cookie or proxy with X-Forwarded-User
  res.redirect(gristUrl);
});
```

---

## Document Lifecycle

### 1. Creation

```
User clicks "New Project" in WeWeb
  ↓
POST /api/projects { name: "Q1 Budget" }
  ↓
Backend creates Grist document
  ↓
Backend stores mapping in Supabase
  ↓
Backend grants creator "owners" role
  ↓
WeWeb displays new project
```

### 2. Collaboration

```
Owner invites team member
  ↓
POST /api/projects/{id}/users { email: "...", role: "editors" }
  ↓
Backend updates Grist ACL
  ↓
Backend stores in Supabase project_users
  ↓
Team member can now access document
```

### 3. Editing

```
User opens project
  ↓
WeWeb embeds Grist iFrame
  ↓
Backend proxies with X-Forwarded-User
  ↓
Grist validates user has access
  ↓
User edits cells, formulas
  ↓
Grist saves automatically to SQLite
  ↓
Changes sync to other users via WebSocket
```

### 4. Archiving

```
Admin archives project
  ↓
PATCH /api/projects/{id} { archived_at: "now" }
  ↓
Backend soft-deletes in Supabase
  ↓
(Optional) Backend exports .grist file to Supabase Storage
  ↓
(Optional) Backend deletes from Grist
  ↓
Project hidden from user's list
```

### 5. Restoration (if needed)

```
Admin restores project
  ↓
PATCH /api/projects/{id} { archived_at: null }
  ↓
(If deleted from Grist) Backend re-imports from Supabase Storage
  ↓
Backend updates mappings
  ↓
Project visible again
```

---

## Permission Management

### Role Mapping

| Supabase Role | Grist Role | Permissions |
|--------------|-----------|-------------|
| `tenant.owner` | `owners` (default workspace access) | Full control of all tenant projects |
| `tenant.admin` | `editors` (default workspace access) | Edit all tenant projects |
| `tenant.member` | `viewers` (default workspace access) | View all tenant projects |
| `project_users.owners` | `owners` (specific doc) | Full control of specific project |
| `project_users.editors` | `editors` (specific doc) | Edit specific project |
| `project_users.viewers` | `viewers` (specific doc) | View specific project |

### Permission Sync Strategy

**Option A: Lazy Sync (Recommended)**
- Sync permissions only when explicitly granted/revoked via API
- Simpler to implement
- Faster for most operations
- May have brief inconsistencies if Supabase is manually edited

**Option B: Scheduled Sync**
- Cron job runs every N minutes
- Compares Supabase vs Grist
- Reconciles differences
- More robust but complex

**Option C: Event-Driven Sync**
- Supabase webhook triggers on permission changes
- Backend syncs to Grist immediately
- Real-time consistency
- Requires webhook infrastructure

**Implementation (Option A):**

```typescript
// src/services/sync.service.ts

export class SyncService {
  async syncProjectPermissions(projectId: string) {
    // 1. Get Supabase permissions
    const { data: project } = await supabase
      .from('projects')
      .select('grist_doc_id, project_users(user_id, grist_role, auth.users(email))')
      .eq('id', projectId)
      .single();

    // 2. Get Grist permissions
    const gristAccess = await gristService.getDocumentAccess(project.grist_doc_id);

    // 3. Calculate delta
    const supabaseUsers = new Map(
      project.project_users.map(pu => [pu.users.email, pu.grist_role])
    );
    
    const gristUsers = new Map(
      gristAccess.users.map(u => [u.email, u.access])
    );

    // 4. Apply changes
    for (const [email, role] of supabaseUsers) {
      if (gristUsers.get(email) !== role) {
        await gristService.grantDocumentAccess(project.grist_doc_id, email, role);
      }
    }

    // 5. Remove users not in Supabase
    for (const [email] of gristUsers) {
      if (!supabaseUsers.has(email)) {
        await gristService.revokeDocumentAccess(project.grist_doc_id, email);
      }
    }
  }
}
```

---

## WeWeb Integration

### 1. Project List Component

```javascript
// In WeWeb Logic
async function fetchProjects() {
  const token = supabase.auth.session().access_token;
  const tenantId = getCurrentTenant().id;
  
  const response = await fetch('https://your-backend.railway.app/api/projects', {
    headers: {
      'Authorization': `Bearer ${token}`,
      'X-Tenant-Id': tenantId,
    },
  });
  
  const { projects } = await response.json();
  return projects;
}
```

### 2. Project Creation

```javascript
async function createProject(name, description) {
  const token = supabase.auth.session().access_token;
  const tenantId = getCurrentTenant().id;
  
  const response = await fetch('https://your-backend.railway.app/api/projects', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'X-Tenant-Id': tenantId,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ name, description }),
  });
  
  const { project } = await response.json();
  return project;
}
```

### 3. Grist Embed Component

```html
<!-- WeWeb Component -->
<div class="grist-container">
  <iframe
    :src="gristEmbedUrl"
    width="100%"
    height="100%"
    frameborder="0"
    allow="clipboard-read; clipboard-write"
    @load="onGristLoad"
  ></iframe>
</div>

<script>
export default {
  props: ['projectId'],
  computed: {
    gristEmbedUrl() {
      const token = this.supabaseToken;
      const tenantId = this.currentTenant.id;
      return `https://your-backend.railway.app/api/grist/${this.projectId}/embed?token=${token}&tenantId=${tenantId}`;
    }
  },
  methods: {
    onGristLoad() {
      console.log('Grist document loaded');
    }
  }
}
</script>
```

### 4. Permission Management UI

```html
<!-- Team Members Component -->
<div class="team-members">
  <h3>Team Access</h3>
  
  <button @click="showInviteModal = true">Invite Member</button>
  
  <ul>
    <li v-for="member in projectMembers" :key="member.id">
      {{ member.email }}
      <select v-model="member.role" @change="updateRole(member)">
        <option value="owners">Owner</option>
        <option value="editors">Editor</option>
        <option value="viewers">Viewer</option>
      </select>
      <button @click="removeMember(member)">Remove</button>
    </li>
  </ul>
  
  <!-- Invite Modal -->
  <Modal v-if="showInviteModal" @close="showInviteModal = false">
    <input v-model="inviteEmail" placeholder="Email address" />
    <select v-model="inviteRole">
      <option value="editors">Editor</option>
      <option value="viewers">Viewer</option>
    </select>
    <button @click="inviteMember">Send Invite</button>
  </Modal>
</div>

<script>
export default {
  data() {
    return {
      projectMembers: [],
      showInviteModal: false,
      inviteEmail: '',
      inviteRole: 'editors',
    };
  },
  methods: {
    async inviteMember() {
      const response = await fetch(
        `https://your-backend.railway.app/api/projects/${this.projectId}/users`,
        {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${this.supabaseToken}`,
            'X-Tenant-Id': this.currentTenant.id,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            email: this.inviteEmail,
            role: this.inviteRole,
          }),
        }
      );
      
      if (response.ok) {
        this.showInviteModal = false;
        this.loadMembers();
      }
    },
    
    async updateRole(member) {
      // Update role API call
    },
    
    async removeMember(member) {
      // Remove member API call
    },
  },
};
</script>
```

---

## Deployment Steps

### Phase 1: Infrastructure Setup

#### 1.1 Deploy Grist to Railway

```bash
# Clone Grist repo
git clone https://github.com/gristlabs/grist-core.git
cd grist-core

# Create Railway project
railway init

# Add PostgreSQL (for HomeDB)
railway add postgresql

# Set environment variables in Railway dashboard
# (Use the configuration from section above)

# Deploy
railway up

# Note the deployment URL (e.g., https://grist-production.railway.app)
```

#### 1.2 Setup Supabase

```bash
# Create new Supabase project at https://supabase.com

# Run migrations
psql $SUPABASE_DB_URL < migrations/001_initial_schema.sql

# Enable RLS on all tables
# (Already included in schema above)

# Create Supabase Storage bucket (optional)
# For archiving .grist files
```

#### 1.3 Configure Grist in Railway

```bash
# Test Grist is accessible
curl https://grist-production.railway.app/api/orgs

# Create initial organization via Grist UI or API
# Note the org ID and workspace ID
```

### Phase 2: Backend Development

#### 2.1 Setup Railway Backend

```bash
# Create Node.js project
mkdir railway-backend
cd railway-backend
npm init -y

# Install dependencies
npm install express typescript @types/node @types/express
npm install @supabase/supabase-js axios dotenv
npm install --save-dev tsx nodemon

# Copy project structure from above
# Implement routes and services
```

#### 2.2 Environment Configuration

```bash
# .env
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_SERVICE_KEY=eyJ...
GRIST_URL=https://grist-production.railway.app
GRIST_API_KEY=your_grist_api_key
PORT=3000
```

#### 2.3 Deploy Backend

```bash
railway init
railway up
```

### Phase 3: WeWeb Integration

#### 3.1 Configure Supabase in WeWeb

- Add Supabase plugin
- Configure with project URL and anon key
- Setup authentication flows

#### 3.2 Create API Collection

- Create custom API collection pointing to Railway backend
- Configure authentication (Bearer token from Supabase)
- Add endpoints for projects, users, etc.

#### 3.3 Build UI Components

- Project list page
- Project creation form
- Grist embed component
- Team management component

### Phase 4: Testing

#### 4.1 Test Authentication

```bash
# Login via WeWeb
# Verify JWT is issued
# Test API call to Railway backend
# Verify user can access Grist
```

#### 4.2 Test Multi-Tenancy

```bash
# Create 2 test tenants
# Create projects in each
# Verify tenant A cannot access tenant B's projects
# Verify RLS policies work
```

#### 4.3 Test Collaboration

```bash
# Create project as user A
# Invite user B
# User B opens project
# Make simultaneous edits
# Verify real-time sync works
```

### Phase 5: Production Readiness

#### 5.1 Setup Monitoring

```bash
# Grist metrics
GRIST_PROMCLIENT_PORT=9090

# Add monitoring in Railway
# - CPU/Memory usage
# - Error rates
# - API latency
```

#### 5.2 Backup Strategy

```bash
# Automated Grist backups to Supabase Storage
# (Configure in Grist env vars)

# Supabase automated backups
# (Enabled by default in Supabase)
```

#### 5.3 Security Audit

- [ ] All API endpoints require authentication
- [ ] RLS policies prevent cross-tenant access
- [ ] Grist forward auth headers cannot be spoofed
- [ ] HTTPS enforced everywhere
- [ ] API rate limiting enabled
- [ ] Secrets stored securely (Railway env vars)

---

## Testing Strategy

### Unit Tests

```typescript
// tests/services/grist.service.test.ts

import { GristService } from '../../src/services/grist.service';

describe('GristService', () => {
  let gristService: GristService;
  
  beforeEach(() => {
    gristService = new GristService();
  });
  
  it('should create a document', async () => {
    const doc = await gristService.createDocument(
      1, // workspaceId
      'Test Document'
    );
    
    expect(doc).toHaveProperty('id');
    expect(doc).toHaveProperty('urlId');
  });
  
  it('should grant document access', async () => {
    const result = await gristService.grantDocumentAccess(
      'test-doc-id',
      'user@example.com',
      'editors'
    );
    
    expect(result).toBeTruthy();
  });
});
```

### Integration Tests

```typescript
// tests/integration/project-lifecycle.test.ts

import request from 'supertest';
import app from '../../src/app';

describe('Project Lifecycle', () => {
  let authToken: string;
  let projectId: string;
  
  beforeAll(async () => {
    // Login and get token
    const response = await request(app)
      .post('/auth/login')
      .send({ email: 'test@example.com', password: 'password' });
    
    authToken = response.body.token;
  });
  
  it('should create a project', async () => {
    const response = await request(app)
      .post('/api/projects')
      .set('Authorization', `Bearer ${authToken}`)
      .set('X-Tenant-Id', 'test-tenant-id')
      .send({ name: 'Test Project' });
    
    expect(response.status).toBe(201);
    expect(response.body).toHaveProperty('project');
    projectId = response.body.project.id;
  });
  
  it('should list projects', async () => {
    const response = await request(app)
      .get('/api/projects')
      .set('Authorization', `Bearer ${authToken}`)
      .set('X-Tenant-Id', 'test-tenant-id');
    
    expect(response.status).toBe(200);
    expect(response.body.projects).toHaveLength(1);
  });
  
  it('should grant access to another user', async () => {
    const response = await request(app)
      .post(`/api/projects/${projectId}/users`)
      .set('Authorization', `Bearer ${authToken}`)
      .set('X-Tenant-Id', 'test-tenant-id')
      .send({
        email: 'collaborator@example.com',
        role: 'editors',
      });
    
    expect(response.status).toBe(201);
  });
});
```

### End-to-End Tests (Playwright)

```typescript
// e2e/project-collaboration.spec.ts

import { test, expect } from '@playwright/test';

test('users can collaborate on a project', async ({ page, context }) => {
  // User A creates project
  await page.goto('https://your-weweb-app.com/login');
  await page.fill('input[name=email]', 'userA@example.com');
  await page.fill('input[name=password]', 'password');
  await page.click('button[type=submit]');
  
  await page.goto('https://your-weweb-app.com/projects');
  await page.click('button:has-text("New Project")');
  await page.fill('input[name=name]', 'Collaboration Test');
  await page.click('button:has-text("Create")');
  
  // Invite User B
  await page.click('button:has-text("Invite")');
  await page.fill('input[name=email]', 'userB@example.com');
  await page.selectOption('select[name=role]', 'editors');
  await page.click('button:has-text("Send")');
  
  // Open new tab as User B
  const userBPage = await context.newPage();
  await userBPage.goto('https://your-weweb-app.com/login');
  await userBPage.fill('input[name=email]', 'userB@example.com');
  await userBPage.fill('input[name=password]', 'password');
  await userBPage.click('button[type=submit]');
  
  await userBPage.goto('https://your-weweb-app.com/projects');
  await expect(userBPage.locator('text=Collaboration Test')).toBeVisible();
  
  // Both users edit the same document
  // (More complex Grist interaction testing)
});
```

---

## Monitoring & Maintenance

### Key Metrics to Track

#### 1. Grist Performance

```bash
# Enable Prometheus metrics
GRIST_PROMCLIENT_PORT=9090

# Monitor:
# - Active documents
# - Memory usage per document
# - WebSocket connections
# - Python sandbox performance
# - API request latency
```

#### 2. Backend API

```typescript
// Add metrics middleware
import prometheus from 'prom-client';

const httpRequestDuration = new prometheus.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
});

app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    httpRequestDuration.labels(req.method, req.route?.path, res.statusCode).observe(duration);
  });
  next();
});

// Metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', prometheus.register.contentType);
  res.end(await prometheus.register.metrics());
});
```

#### 3. Database Queries

```sql
-- Monitor slow queries in Supabase dashboard

-- Check sync log for failures
SELECT 
  entity_type,
  action,
  COUNT(*) as count,
  COUNT(*) FILTER (WHERE status = 'failed') as failures
FROM grist_sync_log
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY entity_type, action;
```

### Backup Procedures

#### Daily Backups

```bash
# Grist documents (via S3 sync)
# Configured in Grist env vars
GRIST_DOCS_S3_BUCKET=grist-documents
# Grist handles automatic syncing

# Supabase (automatic)
# Enabled by default, accessible in dashboard

# Additional manual backup script
#!/bin/bash
# backup.sh

DATE=$(date +%Y-%m-%d)

# Backup Supabase DB
pg_dump $SUPABASE_DB_URL > backups/supabase-$DATE.sql

# Download all Grist documents
curl -H "Authorization: Bearer $GRIST_API_KEY" \
  https://grist-production.railway.app/api/docs \
  | jq -r '.[].id' \
  | while read docId; do
      curl -H "Authorization: Bearer $GRIST_API_KEY" \
        https://grist-production.railway.app/api/docs/$docId/download \
        -o backups/grist-$docId-$DATE.grist
    done
```

### Health Checks

```typescript
// src/routes/health.ts

router.get('/health', async (req, res) => {
  const checks = {
    supabase: false,
    grist: false,
    database: false,
  };
  
  try {
    // Check Supabase
    const { error } = await supabase.from('tenants').select('id').limit(1);
    checks.supabase = !error;
    
    // Check Grist
    const gristResponse = await axios.get(`${process.env.GRIST_URL}/api/orgs`, {
      headers: { Authorization: `Bearer ${process.env.GRIST_API_KEY}` },
      timeout: 5000,
    });
    checks.grist = gristResponse.status === 200;
    
    // Check database
    checks.database = checks.supabase; // Using Supabase as DB
    
    const healthy = Object.values(checks).every(v => v);
    
    res.status(healthy ? 200 : 503).json({
      status: healthy ? 'healthy' : 'unhealthy',
      checks,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    res.status(503).json({
      status: 'unhealthy',
      checks,
      error: error.message,
    });
  }
});
```

---

## Troubleshooting

### Common Issues

#### Issue: User can't access Grist document

**Symptoms:**
- Grist shows "Access denied"
- iFrame doesn't load

**Diagnosis:**
```sql
-- Check Supabase permissions
SELECT * FROM project_users 
WHERE project_id = '{projectId}' 
  AND user_id = '{userId}';

-- Check Grist sync log
SELECT * FROM grist_sync_log
WHERE entity_id = '{gristDocId}'
  AND entity_type = 'user_access'
ORDER BY created_at DESC
LIMIT 10;
```

**Solutions:**
1. Re-sync permissions: `POST /api/projects/{id}/sync`
2. Check Grist ACL directly: `GET https://grist.../api/docs/{docId}/access`
3. Verify X-Forwarded-User header is being set

#### Issue: Grist document not loading

**Symptoms:**
- iFrame shows loading spinner indefinitely
- 404 error

**Diagnosis:**
```bash
# Check Grist logs in Railway
railway logs --service grist

# Test direct access
curl -H "Authorization: Bearer $GRIST_API_KEY" \
  https://grist-production.railway.app/api/docs/{docId}
```

**Solutions:**
1. Verify document exists in Grist
2. Check Grist workspace hasn't been deleted
3. Restart Grist service if document is corrupted

#### Issue: Real-time updates not working

**Symptoms:**
- User A makes changes but User B doesn't see them
- Must refresh page to see updates

**Diagnosis:**
```bash
# Check WebSocket connections
# In Grist logs, look for: "client websocket connected"

# Check browser console for WebSocket errors
```

**Solutions:**
1. Verify GRIST_SERVE_SAME_ORIGIN is set correctly
2. Check proxy/load balancer allows WebSocket upgrades
3. Verify firewall doesn't block WebSocket connections

#### Issue: Document creation fails

**Symptoms:**
- API returns 500 error
- Document not created in Grist or Supabase

**Diagnosis:**
```sql
-- Check sync log
SELECT * FROM grist_sync_log
WHERE action = 'create'
  AND status = 'failed'
ORDER BY created_at DESC
LIMIT 10;
```

**Solutions:**
1. Check Grist has available storage
2. Verify workspace exists and is accessible
3. Check API key has correct permissions
4. Ensure transaction isn't failing due to constraint violations

### Debug Mode

```bash
# Enable verbose logging in Railway backend
DEBUG=true
LOG_LEVEL=debug

# Enable Grist debug logging
GRIST_LOG_LEVEL=debug
TYPEORM_LOGGING=true
```

### Support Contacts

- **Grist Community:** https://community.getgrist.com
- **Grist Discord:** https://discord.gg/MYKpYQ3fbP
- **Supabase Support:** support@supabase.io
- **Railway Support:** https://railway.app/help

---

## Appendix

### A. Grist API Reference

**Base URL:** `https://grist-production.railway.app`

#### Organizations

```bash
# List orgs
GET /api/orgs

# Create org
POST /api/orgs
{
  "name": "My Organization",
  "domain": "my-org"
}

# Get org
GET /api/orgs/{orgId}
```

#### Workspaces

```bash
# List workspaces
GET /api/orgs/{orgId}/workspaces

# Create workspace
POST /api/orgs/{orgId}/workspaces
{
  "name": "My Workspace"
}

# Get workspace
GET /api/workspaces/{workspaceId}
```

#### Documents

```bash
# Create document
POST /api/docs
{
  "workspaceId": 123,
  "documentName": "My Document",
  "sourceDocumentId": "optional-template-id"
}

# Get document
GET /api/docs/{docId}

# Delete document
DELETE /api/docs/{docId}

# Download document
GET /api/docs/{docId}/download

# Get document access
GET /api/docs/{docId}/access

# Update document access
PATCH /api/docs/{docId}/access
{
  "delta": {
    "users": {
      "user@example.com": "editors",
      "another@example.com": null  # Remove access
    }
  }
}
```

#### Tables & Records

```bash
# List tables
GET /api/docs/{docId}/tables

# Get records
GET /api/docs/{docId}/tables/{tableId}/records

# Create records
POST /api/docs/{docId}/tables/{tableId}/records
{
  "records": [
    {
      "fields": {
        "Column1": "value1",
        "Column2": 123
      }
    }
  ]
}

# Update records
PATCH /api/docs/{docId}/tables/{tableId}/records
{
  "records": [
    {
      "id": 1,
      "fields": {
        "Column1": "updated value"
      }
    }
  ]
}

# Delete records
DELETE /api/docs/{docId}/tables/{tableId}/records
{
  "records": [1, 2, 3]  # Record IDs
}
```

### B. Useful SQL Queries

```sql
-- Get all projects for a tenant with member count
SELECT 
  p.*,
  COUNT(DISTINCT pu.user_id) as member_count
FROM projects p
LEFT JOIN project_users pu ON pu.project_id = p.id
WHERE p.tenant_id = '{tenantId}'
  AND p.archived_at IS NULL
GROUP BY p.id
ORDER BY p.created_at DESC;

-- Get user's accessible projects
SELECT 
  p.*,
  pu.grist_role as my_role
FROM projects p
JOIN project_users pu ON pu.project_id = p.id
WHERE pu.user_id = '{userId}'
  AND p.archived_at IS NULL;

-- Audit log: Recent permission changes
SELECT 
  p.name as project_name,
  u.email as user_email,
  pu.grist_role,
  pu.granted_at,
  granter.email as granted_by
FROM project_users pu
JOIN projects p ON p.id = pu.project_id
JOIN auth.users u ON u.id = pu.user_id
LEFT JOIN auth.users granter ON granter.id = pu.granted_by
WHERE p.tenant_id = '{tenantId}'
ORDER BY pu.granted_at DESC
LIMIT 50;

-- Failed sync operations
SELECT *
FROM grist_sync_log
WHERE status = 'failed'
  AND created_at > NOW() - INTERVAL '7 days'
ORDER BY created_at DESC;
```

### C. Environment Variables Checklist

```bash
# Grist (Railway)
✓ GRIST_HOST
✓ PORT
✓ GRIST_ORG_IN_PATH
✓ GRIST_SINGLE_ORG
✓ GRIST_FORWARD_AUTH_HEADER
✓ GRIST_FORCE_LOGIN
✓ GRIST_SESSION_SECRET
✓ TYPEORM_TYPE
✓ TYPEORM_HOST (if Postgres)
✓ TYPEORM_DATABASE

# Backend (Railway)
✓ SUPABASE_URL
✓ SUPABASE_SERVICE_KEY
✓ GRIST_URL
✓ GRIST_API_KEY
✓ PORT

# WeWeb
✓ SUPABASE_URL (public)
✓ SUPABASE_ANON_KEY (public)
✓ BACKEND_API_URL
```

### D. Deployment Checklist

- [ ] Grist deployed to Railway
- [ ] Grist accessible via HTTPS
- [ ] Supabase project created
- [ ] Database schema migrated
- [ ] RLS policies enabled
- [ ] Backend deployed to Railway
- [ ] Backend can connect to Supabase
- [ ] Backend can connect to Grist
- [ ] WeWeb configured with Supabase
- [ ] WeWeb can call backend API
- [ ] Test user can login
- [ ] Test user can create project
- [ ] Test user can view project in Grist
- [ ] Test collaboration works
- [ ] Test multi-tenancy isolation
- [ ] Monitoring enabled
- [ ] Backups configured
- [ ] Health checks passing

---

## Next Steps

1. **Review this plan** with your team
2. **Provision infrastructure** (Supabase, Railway)
3. **Deploy Grist** and configure environment
4. **Develop backend API** following the structure above
5. **Integrate with WeWeb** and build UI components
6. **Test thoroughly** with multiple users and tenants
7. **Launch MVP** with a small group of beta users
8. **Iterate** based on feedback

---

**Document Version:** 1.0  
**Last Updated:** 2025-11-24  
**Maintained By:** Development Team

For questions or updates to this plan, please create an issue in the project repository.

