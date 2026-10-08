# OAuth Client Manager for SAS Viya

This script allows SAS Viya administrators to automate the lifecycle management of OAuth clients, including client registration, retrieval, deletion, and inventory reporting. The script removes the dependency on manual user sign-ins during the client registration process, making it well suited for automation.

## Features

- **Register OAuth Clients**: Onboard new OAuth clients without requiring an interactive user login.
- **Delete OAuth Clients**: Securely remove OAuth clients and their associated credentials.
- **List OAuth Clients**: View all non-system OAuth clients in your Viya environment.


## Requirements
> [!IMPORTANT] SAS Viya administrator privileges are required to use this script.
* `sas-viya`: The Viya CLI, installed and properly configured
* `jq`: A JSON query processor for parsing API responses
* `curl`: A tool for making HTTP requests


## Setup

### Environment Variables Configuration

| Variable | Purpose | Example |
|----------|---------|---------|
| `SAS_CLI_PROFILE` | Viya CLI profile to use | `export SAS_CLI_PROFILE=dev` |

### 1. Configure Viya CLI

[See Viya's CLI documentation](https://go.documentation.sas.com/doc/en/sasadmincdc/default/calcli/n01xwtcatlinzrn1gztsglukb34a.htm) for more details on configuring and using the CLI.

```bash
# Set the Viya CLI profile
export SAS_CLI_PROFILE=<your-viya-cli-profile>


# Authenticate with Viya
sas-viya auth login
```

### 2. Script Configuration

Use the `CREATE_RECORD` environment variable to control whether a JSON file containing client credentials is created. The default value is `false`; no JSON file is created unless the variable is explicitly set to `true`.


```bash
# Create a JSON file with client credentials (default: false)
export CREATE_RECORD=false
```

## Usage

### Basic Command Structure

```bash
./oauth-client-manager.sh [--insecure|-k] <command> [--options]
```

> [!NOTE] When registering a client, the script automatically prepends `client.` to the client ID (for example, `myapp` becomes `client.myapp`).

### Register a New OAuth Client

```bash
./oauth-client-manager.sh register \
  --client-id <client_id> \
  --client-secret <client_secret> \
  --refresh-token-validity <refresh_token_validity> \
  --user-id <user_id> \
  --user-passwd <password>
```

**Parameters:**
-- `--client-id`: A unique client identifier (prefixed with `client.`)
-- `--client-secret`: The client secret (a strong password is recommended)
-- `--refresh-token-validity`: The refresh token validity period, in seconds (for example, 3600 = 60 minutes)
-- `--user-id`: The service account's user ID that will be impersonated by the OAuth client
-- `--user-passwd`: Service account's password

**Example:**
```bash
./oauth-client-manager.sh register \
  --client-id myapp \
  --client-secret <A Complex Password> \
  --refresh-token-validity 3600 \
  --user-id sa-admin@example.com \
  --user-passwd <user_id's password>
```

### List All OAuth Clients
Displays all non-system OAuth clients registered in your Viya environment.
```bash
./oauth-client-manager.sh list
```

### Delete an OAuth Client

```bash
./oauth-client-manager.sh delete \
  --client-id <client_id>
```

> [!WARNING] Deletion is irreversible and will:
> - Remove the OAuth client from Viya
> - Invalidate all tokens issued to this client

**Example:**
```bash
./oauth-client-manager.sh delete --client-id client.myapp
```

### Use an Insecure Connection (Skip TLS Verification)
Use the `-k` or `--insecure` flag to skip TLS certificate verification. This is not recommended for production.
```bash
./oauth-client-manager.sh -k register ...
```


## Notes
- When registering a client, the script automatically prepends `client.` to the client ID (for example, `myapp` becomes `client.myapp`).
- User passwords are required only for initial OAuth client registration, not for subsequent operations.
- This script requires Viya administrator credentials.

## Troubleshooting

### "Viya CLI validation failed"
- Check if Viya CLI is installed
```bash
sas-viya version
```
- Re-authenticate
```bash
sas-viya auth login
```
- Verify profile is set
```bash
echo $SAS_CLI_PROFILE
```
- If you use self-signed certificates, you may need to use the `-k` flag with Viya CLI commands to skip TLS verification. This is not recommended for production.


### "Failed to get SAS services URL"
```bash
# Verify network connectivity
curl -k https://<your-viya-url>:443/SASLogon

# Check Viya CLI configuration
sas-viya profile show
```

### "Failed to register OAuth Client"
- Verify that all required parameters are provided.
- Ensure that `client_id` is unique.
- Check that the user credentials are valid.
- Verify that the user running the script is a Viya administrator.


## Security Best Practices

1. **Use Strong Secrets**: Generate strong, unique client secrets (20+ characters, mixed case, numbers, symbols)
2. **Limit Permissions**: Restrict who can run this script to authorized administrators only
3. **Store Secrets Securely**: Use a Secrets Manager or equivalent secret management solution
4. **Monitor Deletions**: Audit all OAuth client deletions for compliance
5. **Rotate Refresh Tokens Regularly**: Periodically rotate refresh tokens for active clients
6. **Use TLS in Production**: Avoid using `-k` flag in production environments
7. **Secure Credentials**: Never commit client credentials to version control

## Support & Documentation

For more information:
- [SAS Viya CLI documentation](https://go.documentation.sas.com/doc/en/sasadmincdc/default/calcli/n01xwtcatlinzrn1gztsglukb34a.htm)
- [SAS Viya REST API Documentation](https://developer.sas.com/rest-apis)
- [OAuth 2.0 Specification](https://tools.ietf.org/html/rfc6749)

