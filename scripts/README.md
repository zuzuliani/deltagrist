# Deployment Scripts

Automated scripts to help deploy this Grist instance to Railway.

## Quick Start

### Windows (PowerShell)

```powershell
# Open PowerShell in the project root
cd C:\Users\matzu\OneDrive\Documents\GitHub\deltagrist

# Run the setup script
.\scripts\setup-railway.ps1
```

### Mac/Linux (Bash)

```bash
# Make the script executable
chmod +x scripts/setup-railway.sh

# Run it
./scripts/setup-railway.sh
```

## What These Scripts Do

1. ✅ Check if Railway CLI is installed (installs if needed)
2. ✅ Login to Railway
3. ✅ Initialize or link Railway project
4. ✅ Generate secure session secret
5. ✅ Set all required environment variables
6. ✅ (Optional) Add PostgreSQL database
7. ✅ Deploy to Railway

## Manual Setup

If you prefer to set up manually, see `DEPLOYMENT.md` for step-by-step instructions.

## After Running the Script

1. **Wait for deployment** (~5-10 minutes)
2. **Get your URL** from Railway dashboard
3. **Test the deployment:**
   ```bash
   curl https://your-url.railway.app/status/hooks
   ```
4. **Create your first organization** (see `DEPLOYMENT.md`)
5. **Generate API key** for backend integration

## Troubleshooting

### "Railway CLI not found"
Install it manually:
```bash
npm install -g @railway/cli
```

### "Permission denied" (Mac/Linux)
Make the script executable:
```bash
chmod +x scripts/setup-railway.sh
```

### "Execution Policy" error (Windows)
Run PowerShell as Administrator and execute:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## Support

- See `DEPLOYMENT.md` for detailed deployment guide
- See `implementation_plan.md` for full architecture
- Railway Docs: https://docs.railway.app

