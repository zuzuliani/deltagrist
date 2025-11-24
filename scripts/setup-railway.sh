#!/bin/bash
# Setup script for deploying Grist to Railway
# Run this before deploying

set -e

echo "🚂 Grist → Railway Setup Script"
echo "================================"
echo ""

# Check if Railway CLI is installed
if ! command -v railway &> /dev/null; then
    echo "⚠️  Railway CLI not found"
    echo "Install it with: npm install -g @railway/cli"
    echo ""
    read -p "Install Railway CLI now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        npm install -g @railway/cli
    else
        echo "Please install Railway CLI and run this script again"
        exit 1
    fi
fi

# Login to Railway
echo ""
echo "Step 1: Login to Railway"
echo "========================"
railway login

# Initialize project
echo ""
echo "Step 2: Initialize Railway Project"
echo "==================================="
read -p "Create new project or link existing? (new/existing) " project_type

if [ "$project_type" = "new" ]; then
    railway init
else
    railway link
fi

# Generate session secret
echo ""
echo "Step 3: Generate Security Secret"
echo "================================="
SESSION_SECRET=$(openssl rand -hex 32)
echo "✅ Generated session secret: $SESSION_SECRET"

# Get SaaS name
echo ""
echo "Step 4: Configure Organization"
echo "=============================="
read -p "Enter your SaaS name (lowercase, no spaces): " SAAS_NAME

# Set critical environment variables
echo ""
echo "Step 5: Setting Environment Variables"
echo "====================================="

railway variables set \
  PORT=8484 \
  GRIST_HOST=0.0.0.0 \
  GRIST_SINGLE_PORT=true \
  GRIST_SERVE_SAME_ORIGIN=true \
  GRIST_ORG_IN_PATH=true \
  GRIST_SINGLE_ORG="$SAAS_NAME" \
  GRIST_SESSION_SECRET="$SESSION_SECRET" \
  GRIST_FORCE_LOGIN=true \
  GRIST_ANON_PLAYGROUND=false \
  GRIST_DATA_DIR=/persist/docs \
  GRIST_INST_DIR=/persist \
  TYPEORM_TYPE=sqlite \
  TYPEORM_DATABASE=/persist/home.sqlite3 \
  GRIST_FORWARD_AUTH_HEADER=X-Forwarded-User \
  GRIST_HIDE_UI_ELEMENTS=billing,templates,tutorials,supportGrist \
  GRIST_TELEMETRY_LEVEL=off \
  GRIST_SANDBOX_FLAVOR=unsandboxed \
  NODE_ENV=production

echo "✅ Environment variables set"

# Add PostgreSQL option
echo ""
echo "Step 6: Database Selection"
echo "=========================="
read -p "Add PostgreSQL? (recommended for production) (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Creating PostgreSQL database..."
    railway add postgresql
    
    echo ""
    echo "Updating database variables..."
    railway variables set \
      TYPEORM_TYPE=postgres \
      TYPEORM_HOST='${PGHOST}' \
      TYPEORM_PORT='${PGPORT}' \
      TYPEORM_DATABASE='${PGDATABASE}' \
      TYPEORM_USERNAME='${PGUSER}' \
      TYPEORM_PASSWORD='${PGPASSWORD}'
    
    railway variables delete TYPEORM_DATABASE=/persist/home.sqlite3
    echo "✅ PostgreSQL configured"
else
    echo "Using SQLite (configured)"
fi

# Volume reminder
echo ""
echo "⚠️  IMPORTANT: Add Persistent Volume"
echo "===================================="
echo "1. Go to Railway Dashboard"
echo "2. Open your Grist service"
echo "3. Settings → Volumes → Add Volume"
echo "4. Mount Path: /persist"
echo ""
read -p "Press Enter after you've added the volume..."

# Deploy
echo ""
echo "Step 7: Deploy to Railway"
echo "========================="
read -p "Deploy now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deploying..."
    railway up
    
    echo ""
    echo "✅ Deployment started!"
    echo ""
    echo "Monitor progress with: railway logs"
    echo "Open in browser with: railway open"
else
    echo "Skipped deployment"
    echo "Deploy later with: railway up"
fi

# Summary
echo ""
echo "=========================================="
echo "✅ Setup Complete!"
echo "=========================================="
echo ""
echo "📝 Important Information:"
echo "  - SaaS Name: $SAAS_NAME"
echo "  - Session Secret: $SESSION_SECRET"
echo ""
echo "📋 Next Steps:"
echo "  1. Wait for deployment to complete (~5-10 min)"
echo "  2. Get your Railway URL from dashboard"
echo "  3. Test: curl https://your-url.railway.app/status/hooks"
echo "  4. Create first organization (see DEPLOYMENT.md)"
echo "  5. Generate API key for backend integration"
echo ""
echo "📖 Full guide: See DEPLOYMENT.md"
echo "=========================================="

