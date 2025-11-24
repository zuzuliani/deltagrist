# Setup script for deploying Grist to Railway (Windows PowerShell)
# Run this before deploying

Write-Host "🚂 Grist → Railway Setup Script" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Check if Railway CLI is installed
$railwayExists = Get-Command railway -ErrorAction SilentlyContinue
if (-not $railwayExists) {
    Write-Host "⚠️  Railway CLI not found" -ForegroundColor Yellow
    Write-Host "Install it with: npm install -g @railway/cli"
    Write-Host ""
    $install = Read-Host "Install Railway CLI now? (y/n)"
    if ($install -eq "y") {
        npm install -g @railway/cli
    } else {
        Write-Host "Please install Railway CLI and run this script again" -ForegroundColor Red
        exit 1
    }
}

# Login to Railway
Write-Host ""
Write-Host "Step 1: Login to Railway" -ForegroundColor Green
Write-Host "========================"
railway login

# Initialize project
Write-Host ""
Write-Host "Step 2: Initialize Railway Project" -ForegroundColor Green
Write-Host "==================================="
$projectType = Read-Host "Create new project or link existing? (new/existing)"

if ($projectType -eq "new") {
    railway init
} else {
    railway link
}

# Generate session secret
Write-Host ""
Write-Host "Step 3: Generate Security Secret" -ForegroundColor Green
Write-Host "================================="

# Generate random hex string (PowerShell equivalent of openssl rand -hex 32)
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$SESSION_SECRET = [System.BitConverter]::ToString($bytes).Replace("-", "").ToLower()

Write-Host "✅ Generated session secret: $SESSION_SECRET" -ForegroundColor Green

# Get SaaS name
Write-Host ""
Write-Host "Step 4: Configure Organization" -ForegroundColor Green
Write-Host "=============================="
$SAAS_NAME = Read-Host "Enter your SaaS name (lowercase, no spaces)"

# Set critical environment variables
Write-Host ""
Write-Host "Step 5: Setting Environment Variables" -ForegroundColor Green
Write-Host "====================================="

$envVars = @{
    "PORT" = "8484"
    "GRIST_HOST" = "0.0.0.0"
    "GRIST_SINGLE_PORT" = "true"
    "GRIST_SERVE_SAME_ORIGIN" = "true"
    "GRIST_ORG_IN_PATH" = "true"
    "GRIST_SINGLE_ORG" = $SAAS_NAME
    "GRIST_SESSION_SECRET" = $SESSION_SECRET
    "GRIST_FORCE_LOGIN" = "true"
    "GRIST_ANON_PLAYGROUND" = "false"
    "GRIST_DATA_DIR" = "/persist/docs"
    "GRIST_INST_DIR" = "/persist"
    "TYPEORM_TYPE" = "sqlite"
    "TYPEORM_DATABASE" = "/persist/home.sqlite3"
    "GRIST_FORWARD_AUTH_HEADER" = "X-Forwarded-User"
    "GRIST_HIDE_UI_ELEMENTS" = "billing,templates,tutorials,supportGrist"
    "GRIST_TELEMETRY_LEVEL" = "off"
    "GRIST_SANDBOX_FLAVOR" = "unsandboxed"
    "NODE_ENV" = "production"
}

foreach ($key in $envVars.Keys) {
    railway variables set "$key=$($envVars[$key])"
}

Write-Host "✅ Environment variables set" -ForegroundColor Green

# Add PostgreSQL option
Write-Host ""
Write-Host "Step 6: Database Selection" -ForegroundColor Green
Write-Host "=========================="
$addPostgres = Read-Host "Add PostgreSQL? (recommended for production) (y/n)"

if ($addPostgres -eq "y") {
    Write-Host "Creating PostgreSQL database..."
    railway add postgresql
    
    Write-Host ""
    Write-Host "Updating database variables..."
    
    railway variables set "TYPEORM_TYPE=postgres"
    railway variables set "TYPEORM_HOST=`${PGHOST}"
    railway variables set "TYPEORM_PORT=`${PGPORT}"
    railway variables set "TYPEORM_DATABASE=`${PGDATABASE}"
    railway variables set "TYPEORM_USERNAME=`${PGUSER}"
    railway variables set "TYPEORM_PASSWORD=`${PGPASSWORD}"
    
    Write-Host "✅ PostgreSQL configured" -ForegroundColor Green
} else {
    Write-Host "Using SQLite (configured)" -ForegroundColor Yellow
}

# Volume reminder
Write-Host ""
Write-Host "⚠️  IMPORTANT: Add Persistent Volume" -ForegroundColor Yellow
Write-Host "===================================="
Write-Host "1. Go to Railway Dashboard"
Write-Host "2. Open your Grist service"
Write-Host "3. Settings → Volumes → Add Volume"
Write-Host "4. Mount Path: /persist"
Write-Host ""
Read-Host "Press Enter after you've added the volume"

# Deploy
Write-Host ""
Write-Host "Step 7: Deploy to Railway" -ForegroundColor Green
Write-Host "========================="
$deploy = Read-Host "Deploy now? (y/n)"

if ($deploy -eq "y") {
    Write-Host "Deploying..."
    railway up
    
    Write-Host ""
    Write-Host "✅ Deployment started!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Monitor progress with: railway logs"
    Write-Host "Open in browser with: railway open"
} else {
    Write-Host "Skipped deployment" -ForegroundColor Yellow
    Write-Host "Deploy later with: railway up"
}

# Summary
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "✅ Setup Complete!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "📝 Important Information:"
Write-Host "  - SaaS Name: $SAAS_NAME"
Write-Host "  - Session Secret: $SESSION_SECRET"
Write-Host ""
Write-Host "💾 SAVE THIS INFO - You'll need it!"
Write-Host ""
Write-Host "📋 Next Steps:"
Write-Host "  1. Wait for deployment to complete (~5-10 min)"
Write-Host "  2. Get your Railway URL from dashboard"
Write-Host "  3. Test: curl https://your-url.railway.app/status/hooks"
Write-Host "  4. Create first organization (see DEPLOYMENT.md)"
Write-Host "  5. Generate API key for backend integration"
Write-Host ""
Write-Host "📖 Full guide: See DEPLOYMENT.md"
Write-Host "==========================================" -ForegroundColor Cyan

