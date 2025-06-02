###############################################################################################################
##
## Azure IPAM Solution Deployment Script
## Simplified version that reads all configuration from build.json
## 
###############################################################################################################

# Set minimum version requirements
#Requires -Version 7.2
#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.13.0"}
#Requires -Modules @{ ModuleName="Az.Functions"; ModuleVersion="4.0.6"}
#Requires -Modules @{ ModuleName="Az.Resources"; ModuleVersion="6.10.0"}
#Requires -Modules @{ ModuleName="Az.Websites"; ModuleVersion="3.1.1"}
#Requires -Modules @{ ModuleName="Az.KeyVault"; ModuleVersion="4.9.0"}

# Simplified parameters - all configuration comes from build.json
[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$BuildConfigPath = "build.json",
  
  [Parameter(Mandatory = $false)]
  [string]$ZipFilePath,
  
  [Parameter(Mandatory = $false)]
  [switch]$DisableUI,
  
  [Parameter(Mandatory = $false)]
  [switch]$Native,
  
  [Parameter(Mandatory = $false)]
  [string]$UIAppName = 'ipam-ui-app',
  
  [Parameter(Mandatory = $false)]
  [string]$EngineAppName = 'ipam-engine-app',
  
  [Parameter(Mandatory = $false)]
  [string]$Location,
  
  [Parameter(Mandatory = $false)]
  [string]$EngineAppSecret
)

# Root Directory
$ROOT_DIR = (Get-Item $($MyInvocation.MyCommand.Path)).Directory.Parent.FullName

# Check for Debug Flag
$DEBUG_MODE = [bool]$PSCmdlet.MyInvocation.BoundParameters["Debug"].IsPresent

# Set preference variables
$ErrorActionPreference = "Stop"
$DebugPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Hide Azure PowerShell SDK Warnings
$Env:SuppressAzurePowerShellBreakingChangeWarnings = $true

# Hide Azure PowerShell SDK & Azure CLI Survey Prompts
$Env:AzSurveyMessage = $false
$Env:AZURE_CORE_SURVEY_MESSAGE = $false

# Set Log File Location
$logPath = Join-Path -Path $ROOT_DIR -ChildPath "logs"
New-Item -ItemType Directory -Path $logpath -Force | Out-Null

$debugLog = Join-Path -Path $logPath -ChildPath "debug_$(get-date -format `"yyyyMMddhhmmsstt`").log"
$errorLog = Join-Path -Path $logPath -ChildPath "error_$(get-date -format `"yyyyMMddhhmmsstt`").log"
$transcriptLog = Join-Path -Path $logPath -ChildPath "deploy_$(get-date -format `"yyyyMMddhhmmsstt`").log"

$debugSetting = $DEBUG_MODE ? 'Continue' : 'SilentlyContinue'

# Start Transcript
Start-Transcript -Path $transcriptLog

Write-Host "INFO: Loading configuration from $BuildConfigPath"

# Load build configuration
if (-not (Test-Path $BuildConfigPath)) {
    Write-Error "Build configuration file not found: $BuildConfigPath"
    exit 1
}

$BUILD = Get-Content -Path $BuildConfigPath -Raw | ConvertFrom-Json -Depth 15

# Override configuration with command line parameters if provided
if ($Location) { $BUILD.location = $Location }
if ($DisableUI.IsPresent) { $BUILD.ipam.config.disableUI = $true }
if ($Native.IsPresent) { $BUILD.ipam.config.deployAsContainer = $false }

# Extract configuration values
$deployLocation = $BUILD.location
$uiAppId = if (-not $BUILD.ipam.config.disableUI -and $BUILD.ipam.uiAppId) { $BUILD.ipam.uiAppId } else { [GUID]::Empty }
$engineAppId = $BUILD.ipam.engineAppId
$engineSecret = if ($EngineAppSecret) { 
    Write-Host "INFO: Using engine app secret from secure parameter"
    $EngineAppSecret 
} elseif ($BUILD.ipam.engineAppSecret) { 
    Write-Host "INFO: Using engine app secret from build.json (will be migrated to Key Vault)"
    $BUILD.ipam.engineAppSecret 
} else { 
    Write-Warning "No engine app secret provided"
    $null 
}
$resourceNames = $BUILD.ipam.resourceNames
$tags = $BUILD.ipam.config.tags
$deployAsFunc = $BUILD.ipam.config.deployAsFunc
$deployAsContainer = $BUILD.ipam.config.deployAsContainer
$privateAcr = $BUILD.ipam.config.privateAcr

Write-Host "INFO: Configuration loaded successfully"
Write-Host "INFO: Location: $deployLocation"
Write-Host "INFO: Deployment Mode: $(if ($deployAsFunc) { 'Function App' } else { 'App Service' }) $(if (-not $deployAsContainer) { '(Native)' } else { '(Container)' })"
Write-Host "INFO: Resource Group: $($resourceNames.resourceGroupName)"
Write-Host "INFO: Engine App ID: $engineAppId"
if (-not $BUILD.ipam.config.disableUI) {
    Write-Host "INFO: UI App ID: $uiAppId"
}

# Validate required configuration
if (-not $engineAppId) {
    Write-Error "Engine App ID is required in build.json (ipam.engineAppId)"
    exit 1
}

if (-not $engineSecret) {
    Write-Error "Engine App Secret is required in build.json (ipam.engineAppSecret)"
    exit 1
}

$AZURE_ENV_MAP = @{
  AzureCloud        = "AZURE_PUBLIC"
  AzureUSGovernment = "AZURE_US_GOV"
  USSec             = "AZURE_US_GOV_SECRET"
  AzureGermanCloud  = "AZURE_GERMANY"
  AzureChinaCloud   = "AZURE_CHINA"
}

$azureCloud = $AZURE_ENV_MAP[$BUILD.azureCloud]

if (-not $azureCloud) {
  Write-Error "Azure Cloud type is not currently supported: $($BUILD.azureCloud)"
  exit 1
}

# Load Key Vault secret management function
$keyVaultScriptPath = Join-Path $ROOT_DIR "../../scripts/pwsh/Infrastructure/KeyVault/Set-KeyvaultSecret.ps1"
if (Test-Path $keyVaultScriptPath) {
    . $keyVaultScriptPath
} else {
    Write-Warning "Key Vault script not found at: $keyVaultScriptPath"
}

# Deploy-Bicep Function (simplified to use build.json parameters directly)
Function Deploy-Bicep {
    Write-Host "INFO: Deploying IPAM bicep templates with JSON configuration"

    $DebugPreference = $debugSetting

    # Build parameter object for bicep template
    $templateParams = @{
        engineAppId = $engineAppId
        engineAppSecret = $engineSecret
        BUILD = $BUILD
        ipamSpoke = @{
            resourceGroup = @{
                name = $resourceNames.resourceGroupName
            }
            functionApp = @{
                name = $resourceNames.functionName
            }
            appService = @{
                name = $resourceNames.appServiceName
            }
            appServicePlan = @{
                function = $resourceNames.functionPlanName
                app = $resourceNames.appServicePlanName
            }
            cosmosDb = @{
                accountName = $resourceNames.cosmosAccountName
                containerName = $resourceNames.cosmosContainerName
                databaseName = $resourceNames.cosmosDatabaseName
            }
            keyVault = @{
                name = $resourceNames.keyVaultName
            }
            logAnalytics = @{
                name = $resourceNames.workspaceName
            }
            managedIdentity = @{
                name = $resourceNames.managedIdentityName
            }
            storageAccount = @{
                name = $resourceNames.storageAccountName
            }
            containerRegistry = @{
                name = $resourceNames.containerRegistryName
            }
        }
        ipamConfig = @{
            location = $deployLocation
            azureCloud = $BUILD.azureCloud
            privateAcr = $privateAcr
            deployAsFunc = $deployAsFunc
            deployAsContainer = $deployAsContainer
            uiAppId = $uiAppId
            tags = $tags
        }
    }

    Write-Host "INFO: Deploying bicep template with verbose output enabled..."
    Write-Host "INFO: Deployment Name: ipamInfraDeploy-$(Get-Date -Format `"yyyyMMddhhmmsstt`")"
    Write-Host "INFO: Location: $deployLocation"
    Write-Host "INFO: Template File: main.bicep"

    # Deploy IPAM bicep template with parameters and verbose output
    $deployment = New-AzSubscriptionDeployment `
        -Name "ipamInfraDeploy-$(Get-Date -Format `"yyyyMMddhhmmsstt`")" `
        -Location $deployLocation `
        -TemplateFile "main.bicep" `
        -TemplateParameterObject $templateParams `
        -Verbose

    $DebugPreference = 'SilentlyContinue'

    Write-Host "INFO: IPAM bicep templates deployed successfully"
    Write-Host "INFO: Deployment ID: $($deployment.Id)"
    Write-Host "INFO: Deployment State: $($deployment.ProvisioningState)"

    return $deployment
}

Function Get-ZipFile {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$GitHubUserName,
        [Parameter(Mandatory = $true)]
        [string]$GitHubRepoName,
        [Parameter(Mandatory = $true)]
        [string]$ZipFileName,
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$AssetFolder
    )

    $ZipFilePath = Join-Path -Path $AssetFolder.FullName -ChildPath $ZipFileName

    try {
        $GitHubURL = "https://api.github.com/repos/$GitHubUserName/$GitHubRepoName/releases/latest"

        Write-Host "INFO: Target GitHub Repo is " -ForegroundColor Green -NoNewline
        Write-Host "$GitHubUserName/$GitHubRepoName" -ForegroundColor Cyan
        Write-Host "INFO: Fetching download URL..." -ForegroundColor Green

        $GHResponse = Invoke-WebRequest -Method GET -Uri $GitHubURL
        $JSONResponse = $GHResponse.Content | ConvertFrom-Json
        $AssetList = $JSONResponse.assets
        $Asset = $AssetList | Where-Object { $_.name -eq $ZipFileName }
        $DownloadURL = $Asset.browser_download_url

        Write-Host "INFO: Downloading ZIP Archive to " -ForegroundColor Green -NoNewline
        Write-Host $ZipFilePath -ForegroundColor Cyan

        Invoke-WebRequest -Uri $DownloadURL -OutFile $ZipFilePath
    }
    catch {
        Write-Host "ERROR: Unable to download ZIP Deploy archive!" -ForegroundColor Red
        throw $_
    }
}

Function Publish-ZipFile {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$ZipFilePath,
        [Parameter(Mandatory = $false)]
        [switch]$UseAPI
    )

    $publishRetries = 3
    $publishSuccess = $False

    do {
        try {
            if (-not $UseAPI) {
                Write-Host "INFO: Using Publish-AzWebApp for ZIP deployment..." -ForegroundColor Green
                Publish-AzWebApp `
                    -Name $AppName `
                    -ResourceGroupName $ResourceGroupName `
                    -ArchivePath $ZipFilePath `
                    -Restart `
                    -Force `
                | Out-Null
            }
            else {
                Write-Host "INFO: Using Kudu API for ZIP deployment..." -ForegroundColor Green
                
                # Get publishing credentials
                $publishingCredentials = Invoke-AzResourceAction `
                    -ResourceGroupName $ResourceGroupName `
                    -ResourceType Microsoft.Web/sites/config `
                    -ResourceName "$AppName/publishingcredentials" `
                    -Action list `
                    -ApiVersion 2018-02-01 `
                    -Force
                
                $username = $publishingCredentials.Properties.publishingUserName
                $password = $publishingCredentials.Properties.publishingPassword
                
                # Create credentials for Kudu
                $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username, $password)))
                
                # Upload via Kudu API
                $kuduApiUrl = "https://$AppName.scm.azurewebsites.net/api/zipdeploy"
                
                $headers = @{
                    Authorization = "Basic $base64AuthInfo"
                }
                
                Write-Host "INFO: Uploading ZIP to Kudu API endpoint..." -ForegroundColor Green
                $response = Invoke-RestMethod -Uri $kuduApiUrl -Method POST -InFile $ZipFilePath -Headers $headers -ContentType "application/zip" -TimeoutSec 1800
                
                Write-Host "INFO: Kudu API response: $response" -ForegroundColor Green
            }

            $publishSuccess = $True
            Write-Host "INFO: ZIP Deploy archive successfully uploaded" -ForegroundColor Green
        }
        catch {
            if ($publishRetries -gt 0) {
                Write-Host "WARNING: Problem while uploading ZIP Deploy archive! Retrying..." -ForegroundColor Yellow
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                $publishRetries--
                Start-Sleep -Seconds 30  # Wait before retry
            }
            else {
                Write-Host "ERROR: Unable to upload ZIP Deploy archive!" -ForegroundColor Red
                throw $_
            }
        }
    } while ($publishSuccess -eq $False -and $publishRetries -ge 0)
}

Function Update-UIApplication {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$UIAppId,
        [Parameter(Mandatory = $true)]
        [string]$Endpoint
    )

    Write-Host "INFO: Updating UI Application with SPA configuration" -ForegroundColor Green

    $appServiceEndpoint = "https://$Endpoint"

    # Update UI Application with single-page application configuration
    Update-AzADApplication -ApplicationId $UIAppId -SPARedirectUri $appServiceEndpoint 

    Write-Host "INFO: UI Application SPA configuration update complete" -ForegroundColor Green
}

# Main Deployment Script Section
Write-Host
Write-Host "INFO: Starting IPAM Deployment" -ForegroundColor Green

try {
    # Deploy the infrastructure
    Write-Host "INFO: Deploying IPAM infrastructure..." -ForegroundColor Green
    $deployment = Deploy-Bicep

    # Store engine app secret in Key Vault (after infrastructure is deployed)
    if ($engineSecret -and $resourceNames.keyVaultName) {
        Write-Host ""
        Write-Host "=== KEY VAULT SECRET MANAGEMENT ===" -ForegroundColor Cyan
        Write-Host "INFO: Storing engine app secret in Key Vault..." -ForegroundColor Green
        Write-Host "INFO: Key Vault: $($resourceNames.keyVaultName)" -ForegroundColor White
        Write-Host "INFO: Secret Name: ENGINE-SECRET" -ForegroundColor White
        
        try {
            $secretStored = Set-KeyvaultSecret -KeyVaultName $resourceNames.keyVaultName -SecretName "ENGINE-SECRET" -SecretPlainTextValue $engineSecret
            if ($secretStored) {
                Write-Host "✓ Engine app secret stored securely in Key Vault" -ForegroundColor Green
                
                # Remove secret from build.json if it exists (for security)
                if ($BUILD.ipam.engineAppSecret) {
                    Write-Host "INFO: Removing engine app secret from build.json for security..." -ForegroundColor Yellow
                    $BUILD.ipam.PSObject.Properties.Remove('engineAppSecret')
                    $BUILD | ConvertTo-Json -Depth 15 | Set-Content -Path $BuildConfigPath -Encoding UTF8
                    Write-Host "✓ Engine app secret removed from build.json - now stored securely in Key Vault" -ForegroundColor Green
                }
                
                Write-Host ""
                Write-Host "⚠️  MANUAL ACTION REQUIRED: OPERATIONS TEAM ACCESS" -ForegroundColor Yellow
                Write-Host "Please grant the Operations Team admin access to the Key Vault:" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "STEPS:" -ForegroundColor Cyan
                Write-Host "1. Go to Azure Portal > Key Vaults > $($resourceNames.keyVaultName)" -ForegroundColor Cyan
                Write-Host "2. Click 'Access policies' or 'Access control (IAM)'" -ForegroundColor Cyan
                Write-Host "3. Add the Operations Team with 'Key Vault Administrator' role" -ForegroundColor Cyan
                Write-Host "4. This ensures the ops team can manage secrets for maintenance" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "OR use Azure CLI:" -ForegroundColor Cyan
                Write-Host "az keyvault set-policy --name $($resourceNames.keyVaultName) --object-id <OPS_TEAM_OBJECT_ID> --secret-permissions all --key-permissions all --certificate-permissions all" -ForegroundColor Gray
                Write-Host ""
            }
        }
        catch {
            Write-Warning "Failed to store engine app secret in Key Vault: $_"
            Write-Host ""
            Write-Host "⚠️  MANUAL ACTION REQUIRED: KEY VAULT SECRET" -ForegroundColor Red
            Write-Host "Deployment will continue, but you need to manually add the secret:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "STEPS:" -ForegroundColor Cyan
            Write-Host "1. Go to Azure Portal > Key Vaults > $($resourceNames.keyVaultName)" -ForegroundColor Cyan
            Write-Host "2. Click 'Secrets' > 'Generate/Import'" -ForegroundColor Cyan
            Write-Host "3. Name: ENGINE-SECRET" -ForegroundColor Cyan
            Write-Host "4. Value: [Your Engine App Secret]" -ForegroundColor Cyan
            Write-Host "5. Grant Operations Team admin access (see above)" -ForegroundColor Cyan
            Write-Host ""
        }
    }

    # Handle ZIP deployment for native apps
    if (-not $deployAsContainer) {
        if (-not $ZipFilePath) {
            try {
                # Create a temporary folder path
                $TempFolder = Join-Path -Path $env:TEMP -ChildPath $(New-Guid)

                # Create directory if not exists
                $script:TempFolderObj = New-Item -ItemType Directory -Path $TempFolder -Force
            }
            catch {
                Write-Host "ERROR: Unable to create temp directory to store ZIP archive!" -ForegroundColor Red
                throw $_
            }

            Write-Host "INFO: Fetching latest ZIP Deploy archive..." -ForegroundColor Green

            $GitHubUserName = "Azure"
            $GitHubRepoName = "ipam"
            $ZipFileName = "ipam.zip"

            Get-ZipFile -GitHubUserName $GitHubUserName -GitHubRepoName $GitHubRepoName -ZipFileName $ZipFileName -AssetFolder $TempFolderObj

            $script:ZipFilePath = Join-Path -Path $TempFolderObj.FullName -ChildPath $ZipFileName
        }
        else {
            $script:ZipFilePath = Get-Item -Path $ZipFilePath
        }

        Write-Host "INFO: Uploading ZIP Deploy archive..." -ForegroundColor Green

        try {
            $appServiceName = if ($deployAsFunc) { $deployment.Outputs["functionAppName"].Value } else { $deployment.Outputs["appServiceName"].Value }
            
            # Configure App Service for ZIP deployment
            Write-Host "INFO: Configuring App Service for ZIP deployment..." -ForegroundColor Green
            Set-AzWebApp -Name $appServiceName -ResourceGroupName $deployment.Outputs["resourceGroupName"].Value -AppSettings @{
                "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
                "ENABLE_ORYX_BUILD" = "true"
                "POST_BUILD_SCRIPT_PATH" = ""
            }
            
            Publish-ZipFile -AppName $appServiceName -ResourceGroupName $deployment.Outputs["resourceGroupName"].Value -ZipFilePath $ZipFilePath
        }
        catch {
            Write-Host "WARNING: Retrying ZIP Deploy with alternative method..." -ForegroundColor Yellow
            Publish-ZipFile -AppName $appServiceName -ResourceGroupName $deployment.Outputs["resourceGroupName"].Value -ZipFilePath $ZipFilePath -UseAPI
        }

        if ($TempFolderObj) {
            Write-Host "INFO: Cleaning up temporary directory" -ForegroundColor Green
            Remove-Item -LiteralPath $TempFolderObj.FullName -Force -Recurse -ErrorAction SilentlyContinue
            $script:TempFolderObj = $null
        }
    }

    Write-Host "INFO: Azure IPAM Solution deployed successfully" -ForegroundColor Green

    # Display post-deployment information
    if (-not $BUILD.ipam.config.disableUI -and $BUILD.ipam.uiAppId) {
        $appServiceHostName = $deployment.Outputs["appServiceHostName"].Value
        
        Write-Host
        Write-Host "=== DEPLOYMENT COMPLETE ===" -ForegroundColor Green
        Write-Host "IPAM UI URL: https://$appServiceHostName" -ForegroundColor Cyan
        Write-Host "Engine App ID: $engineAppId" -ForegroundColor White
        Write-Host "UI App ID: $($BUILD.ipam.uiAppId)" -ForegroundColor White
        Write-Host "Key Vault: $($resourceNames.keyVaultName)" -ForegroundColor White
        Write-Host "Resource Group: $($resourceNames.resourceGroupName)" -ForegroundColor White
        Write-Host ""
        Write-Host "=== POST-DEPLOYMENT CHECKLIST ===" -ForegroundColor Yellow
        Write-Host "□ Grant Operations Team access to Key Vault (see instructions above)" -ForegroundColor Yellow
        Write-Host "□ Verify IPAM UI is accessible at the URL above" -ForegroundColor Yellow
        Write-Host "□ Test IPAM Engine API functionality" -ForegroundColor Yellow
        Write-Host "□ Configure IPAM network discovery (if needed)" -ForegroundColor Yellow
        Write-Host ""
    }
}
catch {
    Write-Host "ERROR: Azure IPAM Solution deployment failed!" -ForegroundColor Red
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host "Run Log: $transcriptLog" -ForegroundColor Yellow
    Write-Host "Error Log: $errorLog" -ForegroundColor Yellow
    throw $_
}
finally {
    Stop-Transcript
} 