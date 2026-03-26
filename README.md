# CMK Prerequisites for Azure AI Search

Automates the infrastructure required to configure **Customer-Managed Keys (CMK)** with Azure AI Search. Perfect way to get ready for the bug bash! Instead of manually creating and wiring together a key store, managed identity, search service, and RBAC assignments, this deployment handles all of it in one step.

## What gets deployed

| Resource | Purpose |
|---|---|
| **Azure AI Search** service | The search service, configured with CMK enforcement enabled |
| **Key Vault** *(optional)* | Stores the CMK key; RBAC-enabled, soft-delete and purge-protection on |
| **Managed HSM** *(optional)* | FIPS 140-2 Level 3 hardware key storage alternative to Key Vault |
| **Key** | RSA-2048 key with automatic annual rotation (Key Vault path only) |
| **Managed Identity** | System-assigned, user-assigned, or both — used by Search to access the key |
| **RBAC assignments** | Deploying user → Key Vault Crypto Officer; managed identity → Key Vault Crypto Service Encryption User |

> **Note:** This deployment provisions the infrastructure layer (management plane) only. CMK encryption of individual search objects — indexes, indexers, data sources, synonym maps, skillsets — must be applied when those objects are created via the Search Service REST API. See [Encrypting search objects](#encrypting-search-objects) below.

---

## Prerequisites

- [Azure CLI](https://aka.ms/installazurecliwindows) installed (v2.20+ for built-in Bicep support)
- PowerShell 7+
- Logged in to Azure: `az login`
- Permissions in the target subscription: ability to create resources and assign RBAC roles (Owner or User Access Administrator)

---

## Quick start

**1. Edit parameters**

Open `cmk-prereqs.bicepparam` and set values appropriate for your environment — at minimum `baseName` and `location`. See [Parameters](#parameters) below.

**2. Deploy**

```powershell
./deploy.ps1 -ResourceGroupName "my-cmk-rg"
```

To target a specific subscription:

```powershell
./deploy.ps1 -ResourceGroupName "my-cmk-rg" -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

The script will:
- Resolve your identity automatically from your active `az login` session
- Create the resource group if it does not exist
- Deploy all resources
- Print a summary of outputs (service name, Key Vault URI, CMK key URI, identity IDs)
- For the Managed HSM path: print the activation commands needed before the HSM can be used

---

## Files

| File | Purpose |
|---|---|
| `cmk-prereqs.bicep` | Bicep template — all resource definitions |
| `cmk-prereqs.bicepparam` | Parameter values — edit this before deploying |
| `deploy.ps1` | Deployment driver — handles what Bicep cannot |

---

## Parameters

All parameters are set in `cmk-prereqs.bicepparam`.

### `location`
**Default:** `westus2`

Azure region where all resources are created. Use any valid Azure region name, e.g. `eastus`, `westeurope`.

---

### `baseName`
**Default:** `cmkprereqs`

A short prefix (3–20 lowercase alphanumeric characters) used to name every resource. For example, setting `baseName = 'contoso'` produces:
- `contoso-search` (Search service)
- `contoso-kv` (Key Vault)
- `contoso-hsm` (Managed HSM)
- `contoso-search-id` (User-assigned identity)
- `contoso-cmk` (CMK key)

Choose something unique to your environment to avoid naming conflicts.

---

### `searchSku`
**Default:** `basic`

The Azure AI Search pricing tier. CMK enforcement requires a **billable tier** — the `free` tier does not support CMK.

| Value | Description |
|---|---|
| `free` | Free tier — **does not support CMK** |
| `basic` | Entry-level billable tier. Suitable for development and light workloads |
| `standard` | General-purpose production tier (S1) |
| `standard2` | Higher capacity production tier (S2) |
| `standard3` | Highest capacity standard tier (S3); also supports High Density mode |
| `storage_optimized_l1` | Large index storage, lower query throughput (L1) |
| `storage_optimized_l2` | Largest index storage option (L2) |

---

### `identityType`
**Default:** `UserAssigned`

Controls how the Search service authenticates to the key store to access the CMK key.

| Value | Description | When to choose |
|---|---|---|
| `UserAssigned` | A standalone managed identity resource you create and control | **Recommended for most scenarios.** The identity exists independently of the search service — if you delete and recreate the service, the identity (and its key access) is preserved. Easier to audit and manage across multiple services. |
| `SystemAssigned` | An identity automatically created and managed by Azure, tied to the search service lifecycle | Simpler to set up, but the identity is destroyed if the search service is deleted. Acceptable for dev/test environments. |
| `SystemAssigned,UserAssigned` | Both identity types active simultaneously | Use when you need system-assigned for other Azure integrations while also maintaining a durable user-assigned identity for CMK. |

---

### `keyStoreType`
**Default:** `keyVault`

Controls which key storage resource(s) are created.

| Value | Description | When to choose |
|---|---|---|
| `keyVault` | Standard Azure Key Vault with RBAC authorization | **Recommended for most scenarios.** Fully automated — the CMK key is created and configured by this deployment. Lower cost and operational overhead. |
| `managedHsm` | Azure Key Vault Managed HSM (FIPS 140-2 Level 3) | Choose when your compliance requirements mandate hardware-backed key storage (e.g. FedRAMP High, PCI-DSS, government workloads). Higher cost. **Requires manual activation after deployment** before the HSM can be used — see [Managed HSM post-deployment](#managed-hsm-post-deployment). |
| `both` | Creates both a Key Vault and a Managed HSM | Use when you are evaluating both options side-by-side, or when different workloads in the same environment have different compliance requirements. |

---

## Encrypting search objects

The deployment above configures the infrastructure. To actually encrypt content, each search object must be created with an `encryptionKey` property via the [Search Service REST API](https://learn.microsoft.com/en-us/azure/search/search-security-manage-encryption-keys) (data plane API version `2025-09-01`).

Include the following in the request body when creating any index, indexer, data source, synonym map, or skillset:

```json
{
  "encryptionKey": {
    "keyVaultKeyName": "<key-name>",
    "keyVaultKeyVersion": "<key-version-or-omit-for-latest>",
    "keyVaultUri": "<vault-uri-from-deployment-output>",
    "identity": {
      "@odata.type": "#Microsoft.Azure.Search.DataUserAssignedIdentity",
      "userAssignedIdentity": "<user-assigned-identity-resource-id-from-deployment-output>"
    }
  }
}
```

The deployment outputs the values you need: `keyVaultUri`, `cmkKeyUri`, and `userAssignedIdentityId`.

> **CMK encryption is irreversible.** Once an object is created with a CMK it cannot be changed to unencrypted. The key or key version can be rotated, but encryption cannot be removed.

---

## Managed HSM post-deployment

When `keyStoreType` is `managedHsm` or `both`, the HSM must be activated before it can store keys. The `deploy.ps1` script prints the exact commands after deployment completes. The high-level process is:

1. **Obtain 3 RSA key pairs / certificates** to use as wrapping keys for the security domain
2. **Download the security domain:**
   ```
   az keyvault security-domain download \
     --hsm-name <hsm-name> \
     --sd-wrapping-keys cert1.cer cert2.cer cert3.cer \
     --sd-quorum 2 \
     --security-domain-file sd.json
   ```
3. **Create the CMK key:**
   ```
   az keyvault key create --hsm-name <hsm-name> --name cmk --kty RSA-HSM --size 2048
   ```

Reference: https://learn.microsoft.com/azure/key-vault/managed-hsm/quick-create-cli

---

## Outputs

After a successful deployment, the script prints:

| Output | Description |
|---|---|
| Search Service Name | Resource name of the deployed Search service |
| Search Service Resource ID | Full ARM resource ID |
| Key Vault Name | Name of the Key Vault (if created) |
| Key Vault URI | URI used in `encryptionKey` configuration |
| CMK Key URI | Key URI without version — use this for Search encryption configuration |
| Managed HSM Name | Name of the Managed HSM (if created) |
| User-Assigned Identity Resource ID | Resource ID used in `encryptionKey` configuration |
| User-Assigned Identity Principal ID | Object ID used for additional RBAC assignments |
