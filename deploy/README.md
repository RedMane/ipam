# IPAM Deployment - Standardized Approach

This directory contains the standardized deployment scripts for Azure IPAM (IP Address Management) that follow the established infrastructure deployment patterns.

## Files Overview

| File | Purpose |
|------|---------|
| `main.bicep` | Main Bicep template for IPAM infrastructure |
| `main.bicepparam` | Bicep parameter file with standardized naming |
| `MCase-L3-Apps-IPAM.ps1` | Standardized deployment script |
| `New-IPAMAppRegistrations.ps1` | App registration creation script |
| `deploy.ps1` | Original IPAM deployment script (legacy) |

## Deployment Process

### 1. Prerequisites

- Azure PowerShell logged in with appropriate permissions
- Service Principal with required environment variables:
  - `DEPLOYMENT_CLIENT_ID`
  - `DEPLOYMENT_CLIENT_SECRET` 
  - `DEPLOYMENT_TENANT_ID`

### 2. Create App Registrations (One-time setup)

Before deploying the infrastructure, you need to create the Azure AD App Registrations:

```powershell
# From repository root
.\submodules\ipam\deploy\New-IPAMAppRegistrations.ps1 -UIAppName "ipam-ui-app" -EngineAppName "ipam-engine-app"
```

This will:
- Create the IPAM UI and Engine App Registrations
- Configure required API permissions
- Generate a `main.parameters.json` file with the app IDs and secrets

### 3. Update Bicep Parameters

Copy the app registration details from the generated `main.parameters.json` into the `main.bicepparam` file:

```bicep
// Required engine app registration parameters
param engineAppId = 'your-engine-app-id-here'
param engineAppSecret = 'your-engine-app-secret-here'
```

### 4. Deploy Infrastructure

Deploy the IPAM infrastructure using the standardized script:

```powershell
# From repository root - Deploy
.\submodules\ipam\deploy\MCase-L3-Apps-IPAM.ps1

# What-if deployment (dry run)
.\submodules\ipam\deploy\MCase-L3-Apps-IPAM.ps1 -WhatIfEnabled $true

# Delete resources
.\submodules\ipam\deploy\MCase-L3-Apps-IPAM.ps1 -Delete
```

## Resource Naming Convention

The deployment follows the established naming conventions:

| Resource Type | Naming Pattern | Example |
|---------------|----------------|---------|
| Resource Group | `{client}-rg-{lc}-ipam` | `mcsdev001-rg-cu-ipam` |
| App Service | `{client}-app-ipam-01` | `mcsdev001-app-ipam-01` |
| Function App | `{client}-func-ipam-01` | `mcsdev001-func-ipam-01` |
| Key Vault | `{client}-kv-ipam-01` | `mcsdev001-kv-ipam-01` |
| Cosmos DB | `{client}-cosmos-ipam-01` | `mcsdev001-cosmos-ipam-01` |
| Log Analytics | `{client}-log-ipam-01` | `mcsdev001-log-ipam-01` |
| Managed Identity | `{client}-id-ipam-01` | `mcsdev001-id-ipam-01` |
| Storage Account | `{client}stipam01` | `mcsdev001stipam01` |
| Container Registry | `{client}cripam01` | `mcsdev001cripam01` |

All naming follows the Azure resource abbreviation standards from `docs/references/azure-resource-types.md`.

## Configuration

The deployment is configured through:

1. **`build.json`** - Central configuration (client, location, subscription)
2. **`main.bicepparam`** - IPAM-specific parameters and resource names
3. **Environment Variables** - Service Principal credentials

## Key Features

- ✅ **Standardized Structure**: Follows established deployment script patterns
- ✅ **Bicepparam Integration**: Uses `.bicepparam` files instead of JSON
- ✅ **Azure Standards**: Follows Microsoft naming conventions
- ✅ **Separation of Concerns**: App registration and infrastructure deployment are separate
- ✅ **What-If Support**: Dry-run capability for testing
- ✅ **Cleanup Support**: Delete operations for resource cleanup
- ✅ **Error Handling**: Comprehensive error handling and logging
- ✅ **Path Management**: Consistent relative path handling

## Migration from Legacy Script

The original `deploy.ps1` script handled multiple concerns in a single file. The new approach separates:

1. **App Registration** → `New-IPAMAppRegistrations.ps1`
2. **Infrastructure Deployment** → `MCase-L3-Apps-IPAM.ps1` + `main.bicepparam`
3. **Container Building/ZIP Deployment** → Future separate scripts (not yet implemented)

This separation improves maintainability and follows the established patterns used throughout the infrastructure codebase. 