# Deploying This Repo to Railway

This guide shows how to deploy this Grist-Core instance to Railway.

## Prerequisites

- Railway account (https://railway.app)
- Git installed locally
- This repository cloned locally

## Quick Deploy (3 Steps)

### 1. Push to GitHub

```bash
# If you haven't already, create a new GitHub repo and push this code
git remote add origin https://github.com/YOUR-USERNAME/deltagrist.git
git add .
git commit -m "Add Railway configuration"
git push -u origin main
```

### 2. Connect Railway to GitHub

1. Go to https://railway.app/new
2. Click "Deploy from GitHub repo"
3. Select your `deltagrist` repository
4. Railway will auto-detect the Dockerfile ✅

### 3. Configure Environment Variables

In Railway Dashboard → Your Service → Variables:

**Option A: Use Raw Editor**
1. Click "RAW Editor" tab
2. Copy contents from `railway.env.example`
3. **IMPORTANT:** Generate a new session secret:
   ```bash
   openssl rand -hex 32
   ```
4. Replace `GRIST_SESSION_SECRET` value
5. Change `GRIST_SINGLE_ORG` to your SaaS name
6. Save

**Option B: Use UI**
Copy each variable from `railway.env.example` individually.

### 4. Add Persistent Volume

1. Go to Settings tab
2. Scroll to "Volumes" section
3. Click "Add Volume"
4. Mount Path: `/persist`
5. Save

### 5. Deploy!

Railway will automatically:
- Build the Docker image (~5-8 minutes first time)
- Start the container
- Expose a public URL

---

## Testing Your Deployment

Once deployed, get your URL from Railway dashboard.

```bash
# Set your URL
export GRIST_URL=https://deltagrist-production.railway.app

# Test health endpoint
curl $GRIST_URL/status/hooks
# Should return: {"status":"ok",...}

# Test API
curl $GRIST_URL/api/orgs
# Should return: [] (empty array initially)
```

---

## Optional: Add PostgreSQL

For production, use PostgreSQL instead of SQLite:

1. In Railway dashboard, click "New" → "Database" → "PostgreSQL"
2. Railway will create the database and expose variables
3. In your Grist service variables, update:
   ```bash
   TYPEORM_TYPE=postgres
   TYPEORM_HOST=${PGHOST}
   TYPEORM_PORT=${PGPORT}
   TYPEORM_DATABASE=${PGDATABASE}
   TYPEORM_USERNAME=${PGUSER}
   TYPEORM_PASSWORD=${PGPASSWORD}
   ```
4. Remove the SQLite variables
5. Redeploy

---

## Railway CLI Method (Alternative)

If you prefer using the CLI:

```bash
# Install Railway CLI
npm install -g @railway/cli

# Login
railway login

# Link this directory to Railway
railway init

# Deploy
railway up

# Set variables
railway variables set GRIST_SESSION_SECRET=$(openssl rand -hex 32)
railway variables set GRIST_SINGLE_ORG=mycompany
# ... set other variables from railway.env.example

# Open in browser
railway open
```

---

## Post-Deployment Setup

### 1. Access Grist

Visit your Railway URL in a browser. You should see the Grist login page.

### 2. Create First User

Since `GRIST_FORCE_LOGIN=true`, you need to use the API to create your first org:

```bash
# Get your Railway URL
GRIST_URL=https://deltagrist-production.railway.app

# Access as default user (development only)
# Visit: $GRIST_URL

# Or set a default email for development
railway variables set GRIST_DEFAULT_EMAIL=admin@yourdomain.com
```

### 3. Generate API Key

1. Login to Grist UI
2. Click your profile (top right)
3. Profile Settings → API
4. Generate new API key
5. Save this key - you'll need it for the Railway Backend

### 4. Create Organization

Via UI:
1. Click "Add New" → "Team Site"
2. Name it (e.g., "My SaaS Org")

Or via API:
```bash
curl -X POST $GRIST_URL/api/orgs \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "My SaaS Org", "domain": "myorg"}'
```

### 5. Create Workspace

```bash
curl -X POST $GRIST_URL/api/orgs/{orgId}/workspaces \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "Default Workspace"}'
```

Save the `orgId` and `workspaceId` - you'll need these for your backend!

---

## Monitoring

### View Logs

```bash
# Via CLI
railway logs

# Or in dashboard: Deployments tab → Click deployment → View logs
```

### Health Check

Railway automatically monitors the `/status/hooks` endpoint.

---

## Updating Grist

When you want to update to the latest Grist version:

```bash
# Add upstream Grist repo
git remote add upstream https://github.com/gristlabs/grist-core.git

# Fetch latest
git fetch upstream

# Merge (be careful with conflicts)
git merge upstream/main

# Push
git push origin main

# Railway will auto-deploy
```

---

## Troubleshooting

### Build fails with "Out of memory"

Railway's free tier has 512MB build memory. Upgrade to Hobby plan ($5/month) or use:

```toml
# In railway.toml, change to:
[build]
dockerImage = "gristlabs/grist:latest"
```

### Container crashes on startup

Check logs:
```bash
railway logs --tail 100
```

Common issues:
- Missing `GRIST_SESSION_SECRET`
- Volume not mounted at `/persist`
- Database connection failed

### Can't access via URL

1. Check Settings → Networking → "Generate Domain" is enabled
2. Wait 1-2 minutes after deployment
3. Check deployment status (should be green)

### Documents not persisting

Make sure:
- Volume is mounted at `/persist`
- `GRIST_DATA_DIR=/persist/docs` is set
- No typos in volume path

---

## Next Steps

After Grist is running:

1. ✅ Grist deployed and accessible
2. → Set up Supabase database (see `implementation_plan.md`)
3. → Build Railway Backend API
4. → Integrate with WeWeb

See `implementation_plan.md` for the complete architecture!

---

## Support

- Grist Docs: https://support.getgrist.com
- Railway Docs: https://docs.railway.app
- Grist Community: https://community.getgrist.com

