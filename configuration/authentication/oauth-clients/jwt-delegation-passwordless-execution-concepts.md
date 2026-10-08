# SAS Viya Service Account Authentication Flows

Two distinct sequences make up the full lifecycle for a service account authenticating via OIDC: a **Bootstrap**, and a **Steady State** loop.

This architecture implements an industry-standard enterprise security pattern for **User Delegation & Passwordless Execution** built upon formal IETF OAuth 2.0 and OpenID Connect standards ([RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) and [RFC 6749](https://datatracker.ietf.org/doc/html/rfc6749)).


---

## 1. Bootstrap — One-Time Setup Per Service Account

This is the only phase where human interaction is required. It executes once per service account to establish the initial OAuth 2.0 refresh token.

```mermaid
sequenceDiagram
    autonumber
    actor Admin as Admin / Human
    participant SA as Service Account
    participant Browser
    participant SAS as SAS Logon Manager
    participant OIDC as OIDC Provider
    participant IdS as Identities Service
    participant LDAP as LDAP Directory

    Admin->>SA: Initiate authentication setup
    SA->>Browser: Access SAS Viya endpoint
    Browser->>SAS: Request access
    SAS-->>Browser: Redirect to OIDC provider
    Admin->>OIDC: Interactively authenticate
    OIDC-->>Browser: Return authorization code
    Browser->>SAS: Deliver authorization code
    SAS->>OIDC: Exchange code for ID token
    OIDC-->>SAS: ID token (identity claims)
    SAS->>IdS: Resolve identity & fetch group memberships
    IdS->>LDAP: Look up user record
    LDAP-->>IdS: UID, GID, POSIX attributes & groups
    IdS-->>SAS: Resolved identity + POSIX attributes
    SAS-->>SA: Issue initial access token + refresh token
```

> [!NOTE]
> **Output of this flow**: An initial long-lived `refresh_token`, which is securely stored in Secrets Manager for steady-state automation.

---

## 2. Steady State — Production Automation Loop

Once bootstrapped, all subsequent authentication uses direct REST requests against SAS Logon Manager without interactive sign-in. SAS Viya's Identities service validates account claims against LDAP to ensure alignment with upstream POSIX file permissions.

```mermaid
sequenceDiagram
    autonumber
    participant Automation
    participant Secrets Manager
    participant SAS Logon Manager
    participant SAS Compute

    Automation->>Secrets Manager: Retrieve stored refresh_token
    Automation->>SAS Logon Manager: POST /oauth/token (grant_type=refresh_token)
    SAS Logon Manager-->>Automation: Return fresh access_token
    Automation-->>SAS Logon Manager: POST /oauth/token (grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer)
    SAS Logon Manager-->>Automation: Return fresh access_token + rotated refresh_token
    Automation->>Secrets Manager: Store rotated refresh_token
    Automation->>SAS Compute: Submit batch job (Authorization: Bearer access_token)
```

### Operational Cadence & Rotation Guidelines

- **Renewal Window**: Token renewal must execute before the refresh token validity window expires (14 days by default, or as configured by `refresh_token_validity` on the custom OAuth client).
- **Scheduled Renewal**: Executing the refresh loop on a regular schedule (e.g., daily) keeps credentials perpetually valid without human re-authentication.
- **Concurrency Warning**: Avoid renewing the refresh token on **every single micro-request**, rapid rotation can introduce race conditions between parallel threads reading/writing the stored token. Use the **scheduled renewal** approach instead.

---

## Industry Standards & RFC Compliance

This authentication lifecycle complies with established IETF OAuth 2.0 & OpenID Connect standards for enterprise user delegation and automated credential lifecycle management:

| Workflow Step | Formal Standard / RFC | Description |
| :--- | :--- | :--- |
| **JWT Bearer Assertion Exchange** (Step 5) | [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) *(OAuth 2.0 Profile for JWT Client Authentication and Authorization Grants)* | Defines `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer` and passing a JWT in the `assertion` parameter to exchange an ID token/assertion for an access token. |
| **Token Refresh** (Step 6) | [RFC 6749 §6](https://datatracker.ietf.org/doc/html/rfc6749#section-6) *(The OAuth 2.0 Authorization Framework)* | Defines `grant_type=refresh_token` to issue new access tokens without requiring the user to interactively re-authenticate. |
| **Bearer Token Usage** (Test steps) | [RFC 6750](https://datatracker.ietf.org/doc/html/rfc6750) *(OAuth 2.0 Bearer Token Usage)* | Standardizes sending tokens in the HTTP header as `Authorization: Bearer <access_token>`. |
| **Identity Delegation Scope** | [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html) | Standardizes requesting `scope=openid` to establish user identity (`sub`, `email`, `user_name`). |
| **JWT Format & Claims** | [RFC 7519](https://datatracker.ietf.org/doc/html/rfc7519) *(JSON Web Token)* | Defines the structure of the JSON payload (`iss`, `sub`, `aud`, `exp`, `iat`, `jti`). |