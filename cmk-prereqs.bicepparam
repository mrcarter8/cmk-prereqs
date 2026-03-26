using './cmk-prereqs.bicep'

// ──────────────────────────────────────────────
// Deployment Parameters — edit these before deploying
// ──────────────────────────────────────────────

// Azure region where all resources will be created.
param location = 'westus2'

// Short prefix (3–20 lowercase alphanumeric chars) used to name every resource.
// Example: 'contoso' produces 'contoso-search', 'contoso-kv', etc.
param baseName = 'cmkprereqs'

// Azure AI Search pricing tier.
// Options: free | basic | standard | standard2 | standard3 | storage_optimized_l1 | storage_optimized_l2
// Note: CMK enforcement requires a billable SKU (not 'free').
param searchSku = 'basic'

// Which managed identity type(s) to enable on the Search service.
//   SystemAssigned          – Azure creates and manages the identity automatically.
//   UserAssigned            – A standalone identity resource you control; survives service deletion.
//   SystemAssigned,UserAssigned – Both identities are active simultaneously.
param identityType = 'UserAssigned'

// Which key store(s) to create.
//   keyVault   – Standard Azure Key Vault (RBAC-enabled). CMK key created automatically.
//   managedHsm – FIPS 140-2 Level 3 Hardware Security Module. Requires manual security-domain
//                activation after deployment before keys can be created.
//   both       – Creates both a Key Vault and a Managed HSM.
param keyStoreType = 'keyVault'
