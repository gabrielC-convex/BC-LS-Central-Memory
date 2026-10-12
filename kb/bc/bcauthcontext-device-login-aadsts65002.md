---
name: bcauthcontext-device-login-aadsts65002
description: New-BcAuthContext device login dies with AADSTS65002 because Microsoft cut its own Azure PowerShell first-party client off the Business Central API; the fix is passing your own Entra app registration (public client, BC user_impersonation delegated) as -clientID
tags: [bccontainerhelper, saas, auth, device-login, entra, error-message, troubleshooting]
metadata:
  type: reference
provenance: observed
verified: 2026-08-17
---

`New-BcAuthContext -includeDeviceLogin` (BcContainerHelper ≤ 6.1.15) defaults to Microsoft's
first-party **Azure PowerShell** client id `1950a258-227b-4e31-a9cf-717495945fc2`. Microsoft is
progressively enforcing preauthorization between its first-party apps, and on affected tenants
that client may no longer request tokens for the Business Central API resource
(`996def3d-b36c-4153-8607-a6fd3c01b89f`). The device code is still issued, but the browser
sign-in fails with:

> **AADSTS65002**: Consent between first party application '1950a258-…' and first party resource
> '996def3d-…' must be configured via preauthorization - applications owned and operated by
> Microsoft must get approval from the API owner before requesting tokens for that API.

The rollout is per-tenant — the same script can keep working on one tenant and die on another
the same week. Seen on two unrelated tenants in August 2026.

## Fix — own app registration as the public client

One-time, in **the tenant you sign in to** (Entra admin center → App registrations):

1. **New registration** — any name (e.g. "BC PowerShell Client"), single tenant, no redirect URI.
2. **Authentication → Advanced settings → Allow public client flows = Yes** (this is what
   enables the device-code flow; without it you get AADSTS7000218).
3. **API permissions → Add → Dynamics 365 Business Central → Delegated → `user_impersonation`**,
   then **Grant admin consent** (or let the first device login prompt for user consent if the
   tenant's consent policy allows it).
4. Copy the Application (client) ID and pass it explicitly:

```powershell
$ctx = New-BcAuthContext -clientID '<your-app-client-id>' -tenantID $tenantId -includeDeviceLogin
```

## Side effects to expect

- **Cached refresh tokens die with the old client.** A refresh token is bound to the client it
  was issued to; contexts cached from the `1950a258` era fail to redeem (or will, when the
  tenant gets the enforcement). First run after the switch is a fresh device login.
- **Redeem with the same client id.** When redeeming a saved refresh token later, pass the
  `clientID` stored in the cached auth context, not whatever the current default is —
  `New-BcAuthContext -refreshToken … -clientID $cached.clientID`.
- **CI secrets** that store a serialized BcAuthContext (refresh-token JSON) embed the client id
  they were created with. When such a pipeline starts failing auth, regenerate the secret from a
  context created with the custom client — don't debug the pipeline.
- **The app registration is per-tenant.** A single-tenant client app from tenant A fails on
  tenant B with **AADSTS700016** ("application not found in the directory"). Either register a
  twin app in each tenant, or make one app multi-tenant (signInAudience = AzureADMultipleOrgs)
  and consent to it in each tenant.
- `New-BcAuthContext` **returns `$null` instead of throwing** when a refresh token is rejected —
  wrapper scripts that only try/catch around it will happily continue with a null context.
  Check the return value explicitly.
