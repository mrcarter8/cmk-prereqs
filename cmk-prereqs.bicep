// CMK Prerequisites for Azure AI Search
// Creates: Key Vault and/or Managed HSM, User Assigned Managed Identity, Azure AI Search service,
// CMK key, and all necessary access policies / RBAC assignments.
//
// Deploy via: ./deploy.ps1 -ResourceGroupName <rg> [-SubscriptionId <sub>]

targetScope = 'resourceGroup'

// ──────────────────────────────────────────────
// Parameters  ← values live in cmk-prereqs.bicepparam
// ──────────────────────────────────────────────

// Azure region where all resources will be created.
param location string

// Short prefix (3–20 lowercase alphanumeric chars) used to name every resource.
// Example: 'contoso' produces 'contoso-search', 'contoso-kv', etc.
@minLength(3)
@maxLength(20)
param baseName string

// Azure AI Search pricing tier.
// Note: CMK enforcement requires a billable SKU (not 'free').
@allowed([
  'free'
  'basic'
  'standard'
  'standard2'
  'standard3'
  'storage_optimized_l1'
  'storage_optimized_l2'
])
param searchSku string

// Which managed identity type(s) to enable on the Search service.
//   SystemAssigned          – Azure creates and manages the identity automatically.
//   UserAssigned            – A standalone identity resource you control; survives service deletion.
//   SystemAssigned,UserAssigned – Both identities are active simultaneously.
@allowed([
  'SystemAssigned'
  'UserAssigned'
  'SystemAssigned,UserAssigned'
])
param identityType string

// Which key store(s) to create.
//   keyVault   – Standard Azure Key Vault (RBAC-enabled). CMK key created automatically.
//   managedHsm – FIPS 140-2 Level 3 Hardware Security Module. Requires manual security-domain
//                activation after deployment before keys can be created.
//                See: https://learn.microsoft.com/azure/key-vault/managed-hsm/quick-create-cli
//   both       – Creates both a Key Vault and a Managed HSM.
@allowed([
  'keyVault'
  'managedHsm'
  'both'
])
param keyStoreType string

// Object ID of the user or service principal running this deployment.
// Granted 'Key Vault Crypto Officer' so you can create and manage keys from the portal.
// Always supplied at deploy time by deploy.ps1 — do not set in the parameters file.
param currentUserObjectId string = ''

// ──────────────────────────────────────────────
// Variables
// ──────────────────────────────────────────────

var useKeyVault      = keyStoreType == 'keyVault'   || keyStoreType == 'both'
var useManagedHsm    = keyStoreType == 'managedHsm' || keyStoreType == 'both'
var useSystemAssigned = identityType == 'SystemAssigned' || identityType == 'SystemAssigned,UserAssigned'
var useUserAssigned   = identityType == 'UserAssigned'   || identityType == 'SystemAssigned,UserAssigned'

// Role definition IDs (built-in, tenant-wide constants)
var keyVaultCryptoOfficerRoleId           = '14b46e9e-c2b7-41b4-b07b-48a6ebf60603' // Key Vault Crypto Officer — create/manage keys
var keyVaultCryptoServiceEncryptionRoleId = 'e147488a-f6f5-4113-8e2d-b22465e65bf6' // Key Vault Crypto Service Encryption User

// ──────────────────────────────────────────────
// User Assigned Managed Identity (conditional)
// ──────────────────────────────────────────────

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (useUserAssigned) {
  name: '${baseName}-search-id'
  location: location
}

// ──────────────────────────────────────────────
// Azure AI Search Service
// ──────────────────────────────────────────────

resource searchService 'Microsoft.Search/searchServices@2025-05-01' = {
  name: '${baseName}-search'
  location: location
  sku: {
    name: searchSku
  }
  identity: useUserAssigned
    ? {
        type: identityType
        userAssignedIdentities: {
          '${userAssignedIdentity.id}': {}
        }
      }
    : {
        type: identityType
      }
  properties: {
    encryptionWithCmk: {
      enforcement: 'Enabled'
    }
  }
}

// ──────────────────────────────────────────────
// Key Vault (Standard, RBAC-authorised)
// ──────────────────────────────────────────────

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = if (useKeyVault) {
  name: '${baseName}-kv'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true   // use RBAC instead of access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true     // required for CMK
  }
}

// ──────────────────────────────────────────────
// Managed HSM (conditional)
// ──────────────────────────────────────────────
// Note: After deployment you must activate the HSM security domain before it
// can be used. See: https://learn.microsoft.com/azure/key-vault/managed-hsm/quick-create-cli

resource managedHsm 'Microsoft.KeyVault/managedHSMs@2025-05-01' = if (useManagedHsm) {
  name: '${baseName}-hsm'
  location: location
  sku: {
    family: 'B'
    name: 'Standard_B1'
  }
  properties: {
    tenantId: tenant().tenantId
    // The deploying user is added as an initial HSM admin
    initialAdminObjectIds: [currentUserObjectId]
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
  }
}

// ──────────────────────────────────────────────
// CMK Key (Key Vault path only)
// HSM key management must be done via CLI/SDK after HSM activation.
// ──────────────────────────────────────────────

resource cmkKey 'Microsoft.KeyVault/vaults/keys@2025-05-01' = if (useKeyVault) {
  parent: keyVault
  name: '${baseName}-cmk'
  properties: {
    kty: 'RSA'
    keySize: 2048
    keyOps: [
      'wrapKey'
      'unwrapKey'
      'encrypt'
      'decrypt'
    ]
    attributes: {
      enabled: true
    }
    rotationPolicy: {
      attributes: {
        expiryTime: 'P1Y'
      }
      lifetimeActions: [
        {
          action: { type: 'rotate' }
          trigger: { timeBeforeExpiry: 'P30D' }
        }
        {
          action: { type: 'notify' }
          trigger: { timeBeforeExpiry: 'P60D' }
        }
      ]
    }
  }
}

// ──────────────────────────────────────────────
// RBAC: Current user → Key Vault Crypto Officer
// Grants key create/manage rights (least privilege — no access to secrets or certs)
// ──────────────────────────────────────────────

resource currentUserKvCryptoOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useKeyVault) {
  name: guid(keyVault.id, currentUserObjectId, keyVaultCryptoOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCryptoOfficerRoleId)
    principalId: currentUserObjectId
    principalType: 'User'
  }
}

// ──────────────────────────────────────────────
// RBAC: System-assigned identity → Key Vault Crypto Service Encryption User
// ──────────────────────────────────────────────

resource systemIdentityKvCrypto 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useKeyVault && useSystemAssigned) {
  name: guid(keyVault.id, searchService.id, keyVaultCryptoServiceEncryptionRoleId, 'system')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCryptoServiceEncryptionRoleId)
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ──────────────────────────────────────────────
// RBAC: User-assigned identity → Key Vault Crypto Service Encryption User
// ──────────────────────────────────────────────

resource userIdentityKvCrypto 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useKeyVault && useUserAssigned) {
  name: guid(keyVault.id, userAssignedIdentity.id, keyVaultCryptoServiceEncryptionRoleId, 'user')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCryptoServiceEncryptionRoleId)
    principalId: userAssignedIdentity.?properties.?principalId ?? ''
    principalType: 'ServicePrincipal'
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────

@description('Azure AI Search service name.')
output searchServiceName string = searchService.name

@description('Azure AI Search service resource ID.')
output searchServiceId string = searchService.id

@description('Key Vault name (empty when Key Vault not selected).')
output keyVaultName string = useKeyVault ? (keyVault.?name ?? '') : ''

@description('Key Vault URI (empty when Key Vault not selected).')
output keyVaultUri string = useKeyVault ? (keyVault.?properties.?vaultUri ?? '') : ''

@description('CMK key URI without version — use this when configuring the Search encryption key.')
output cmkKeyUri string = useKeyVault ? (cmkKey.?properties.?keyUri ?? '') : ''

@description('Managed HSM name (empty when Managed HSM not selected).')
output managedHsmName string = useManagedHsm ? (managedHsm.?name ?? '') : ''

@description('User-assigned identity resource ID (empty when only SystemAssigned selected).')
output userAssignedIdentityId string = useUserAssigned ? (userAssignedIdentity.?id ?? '') : ''

@description('User-assigned identity principal ID (empty when only SystemAssigned selected).')
output userAssignedIdentityPrincipalId string = useUserAssigned ? (userAssignedIdentity.?properties.?principalId ?? '') : ''
