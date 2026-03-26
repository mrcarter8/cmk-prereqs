#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys CMK prerequisites for Azure AI Search: Key Vault (or Managed HSM),
    User Assigned Managed Identity, Azure AI Search service, CMK key, and RBAC assignments.

.DESCRIPTION
    This script handles everything that cannot be expressed in Bicep:
      - Resolving the deploying user's object ID automatically
      - Creating the resource group if it does not exist
      - Running the Bicep deployment with the parameters file
      - Printing a structured summary of all deployment outputs
      - Providing post-deployment guidance for the Managed HSM path

    Prerequisites:
      - Azure CLI (az) installed and on PATH
      - Logged in via: az login
      - Bicep CLI installed (comes with Azure CLI >= 2.20)

.PARAMETER ResourceGroupName
    Name of the resource group to deploy into. Created if it does not exist.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the current active subscription.

.PARAMETER ParametersFile
    Path to the Bicep parameters file. Defaults to ./cmk-prereqs.bicepparam.

.PARAMETER DeploymentName
    Name for the ARM deployment. Defaults to 'cmk-prereqs-<timestamp>'.

.EXAMPLE
    ./deploy.ps1 -ResourceGroupName "my-cmk-rg"

.EXAMPLE
    ./deploy.ps1 -ResourceGroupName "my-cmk-rg" -SubscriptionId "00000000-0000-0000-0000-000000000000"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ParametersFile = "./cmk-prereqs.bicepparam",

    [Parameter(Mandatory = $false)]
    [string]$DeploymentName = "cmk-prereqs-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success([string]$Message) {
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Info([string]$Message) {
    Write-Host "    $Message" -ForegroundColor Gray
}

function Invoke-Az([string[]]$AzArgs) {
    $result = az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($AzArgs -join ' ') failed:`n$result"
    }
    return $result
}

# ──────────────────────────────────────────────
# Validate prerequisites
# ──────────────────────────────────────────────

Write-Step "Checking prerequisites"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed or not on PATH. Install from https://aka.ms/installazurecliwindows"
}
Write-Success "Azure CLI found: $(az version --query '\"azure-cli\"' -o tsv)"

# Verify logged in
$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure. Run: az login"
}
$accountObj = $account | ConvertFrom-Json
Write-Success "Logged in as: $($accountObj.user.name)"

# ──────────────────────────────────────────────
# Set subscription
# ──────────────────────────────────────────────

if ($SubscriptionId) {
    Write-Step "Setting subscription to $SubscriptionId"
    Invoke-Az @("account", "set", "--subscription", $SubscriptionId) | Out-Null
} else {
    $SubscriptionId = $accountObj.id
}
Write-Success "Active subscription: $SubscriptionId ($($accountObj.name))"

# ──────────────────────────────────────────────
# Resolve current user's object ID
# ──────────────────────────────────────────────

Write-Step "Resolving deploying user's object ID"

$currentUserObjectId = az ad signed-in-user show --query id -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentUserObjectId)) {
    # Fallback: service principal running the deployment
    $currentUserObjectId = $accountObj.user.name
    Write-Info "Signed-in user query failed; attempting service principal lookup"
    $currentUserObjectId = az ad sp show --id $accountObj.user.name --query id -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not resolve object ID for the current identity. Set currentUserObjectId manually in the parameters file."
    }
}
$currentUserObjectId = $currentUserObjectId.Trim()
Write-Success "Object ID: $currentUserObjectId"

# ──────────────────────────────────────────────
# Ensure resource group exists
# ──────────────────────────────────────────────

Write-Step "Ensuring resource group '$ResourceGroupName' exists"

$rgExists = az group exists --name $ResourceGroupName --output tsv
if ($rgExists -eq "false") {
    # Read location from parameters file to create the RG in the same region
    $paramContent = Get-Content $ParametersFile -Raw
    if ($paramContent -match "param location\s*=\s*'([^']+)'") {
        $rgLocation = $Matches[1]
    } else {
        $rgLocation = "westus2"
        Write-Info "Could not parse location from parameters file; defaulting to westus2"
    }
    Write-Info "Creating resource group in $rgLocation"
    Invoke-Az @("group", "create", "--name", $ResourceGroupName, "--location", $rgLocation) | Out-Null
    Write-Success "Resource group created"
} else {
    Write-Success "Resource group already exists"
}

# ──────────────────────────────────────────────
# Run Bicep deployment
# ──────────────────────────────────────────────

Write-Step "Starting deployment '$DeploymentName'"
Write-Info "Template:   cmk-prereqs.bicep"
Write-Info "Parameters: $ParametersFile"

$stdoutFile = [System.IO.Path]::GetTempFileName()
$stderrFile  = [System.IO.Path]::GetTempFileName()
az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroupName `
    --template-file "$PSScriptRoot/cmk-prereqs.bicep" `
    --parameters "$ParametersFile" `
    --parameters currentUserObjectId=$currentUserObjectId `
    --output json >$stdoutFile 2>$stderrFile

$deployExitCode = $LASTEXITCODE
$deployResult   = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
$stderrContent  = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

function Show-DeploymentErrors {
    # Print the raw CLI error first (covers pre-ARM failures like bad template path or Bicep compile errors)
    if (-not [string]::IsNullOrWhiteSpace($stderrContent)) {
        Write-Host $stderrContent -ForegroundColor DarkRed
    }

    # Then fetch per-resource operation errors from ARM (covers failures inside the deployment itself)
    $opsJson = az deployment operation group list `
        --resource-group $ResourceGroupName `
        --name $DeploymentName `
        --query "[?properties.provisioningState=='Failed'].properties.statusMessage" `
        --output json 2>&1
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($opsJson)) {
        $ops = $opsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        foreach ($op in $ops) {
            $code    = $op.error.code
            $message = $op.error.message
            Write-Host "  [$code] $message" -ForegroundColor Red
            foreach ($detail in $op.error.details) {
                Write-Host "    [$($detail.code)] $($detail.message)" -ForegroundColor DarkRed
            }
        }
    }
}

if ($deployExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($deployResult)) {
    Write-Host "`n[ERROR] Deployment failed." -ForegroundColor Red
    Show-DeploymentErrors
    exit 1
}

$deployment = $deployResult | ConvertFrom-Json -ErrorAction Stop

if ($deployment.properties.provisioningState -ne "Succeeded") {
    Write-Host "`n[ERROR] Deployment state: $($deployment.properties.provisioningState)" -ForegroundColor Red
    Show-DeploymentErrors
    exit 1
}

Write-Success "Deployment succeeded"

# ──────────────────────────────────────────────
# Display outputs
# ──────────────────────────────────────────────

Write-Step "Deployment Outputs"

$outputs = $deployment.properties.outputs

$outputMap = @{
    searchServiceName              = "Search Service Name"
    searchServiceId                = "Search Service Resource ID"
    keyVaultName                   = "Key Vault Name"
    keyVaultUri                    = "Key Vault URI"
    cmkKeyUri                      = "CMK Key URI (use for Search encryption config)"
    managedHsmName                 = "Managed HSM Name"
    userAssignedIdentityId         = "User-Assigned Identity Resource ID"
    userAssignedIdentityPrincipalId = "User-Assigned Identity Principal ID"
}

foreach ($key in $outputMap.Keys) {
    $val = $outputs.$key.value
    if (-not [string]::IsNullOrWhiteSpace($val)) {
        Write-Host ("    {0,-45} {1}" -f "$($outputMap[$key]):", $val) -ForegroundColor White
    }
}

# ──────────────────────────────────────────────
# Post-deployment guidance
# ──────────────────────────────────────────────

$keyStoreType = $null
$paramContent = Get-Content $ParametersFile -Raw
if ($paramContent -match "param keyStoreType\s*=\s*'([^']+)'") {
    $keyStoreType = $Matches[1]
}

if ($keyStoreType -eq "managedHsm" -or $keyStoreType -eq "both") {
    $hsmName = $outputs.managedHsmName.value
    Write-Host "`n[NEXT STEPS — Managed HSM]" -ForegroundColor Yellow
    Write-Host "  The Managed HSM requires security-domain activation before keys can be created." -ForegroundColor Yellow
    Write-Host "  Run the following to download the security domain (requires 3 RSA key pairs):" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    az keyvault security-domain download \\" -ForegroundColor DarkYellow
    Write-Host "      --hsm-name $hsmName \\" -ForegroundColor DarkYellow
    Write-Host "      --sd-wrapping-keys cert1.cer cert2.cer cert3.cer \\" -ForegroundColor DarkYellow
    Write-Host "      --sd-quorum 2 \\" -ForegroundColor DarkYellow
    Write-Host "      --security-domain-file sd.json" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  After activation, create the CMK key:" -ForegroundColor Yellow
    Write-Host "    az keyvault key create --hsm-name $hsmName --name cmk --kty RSA-HSM --size 2048" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  Docs: https://learn.microsoft.com/azure/key-vault/managed-hsm/quick-create-cli" -ForegroundColor Gray
}

Write-Host "`nDone." -ForegroundColor Green
