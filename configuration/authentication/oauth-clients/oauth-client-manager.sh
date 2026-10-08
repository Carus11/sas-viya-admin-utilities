#!/bin/bash
# This script allows SAS Viya administrators to automate the lifecycle management of OAuth clients, 
# including client registration, retrieval, deletion, and inventory reporting. 
# The script removes the dependency on manual user sign-ins during the client registration process, 
# making it well suited for automation.

# Create a JSON file with client credentials (default: false)
CREATE_RECORD=${CREATE_RECORD:-false}

dirname=$(dirname "$0")
thispath=$(cd "$dirname"; pwd)
thisscript=$(basename "$0")
source "$thispath/common/_shared.sh"

function showHelp() {
    echo "Usage: $0 [--insecure|-k] {register|delete|list}"
    echo "  --insecure | -k - Allows connections without TLS verification"
    echo "  register --client-id <client_id> --client-secret <client_secret> --refresh-token-validity <refresh_token_validity> --user-id <user_id> --user-passwd <password>"
    echo "  delete --client-id <client_id>"
    echo "  list - List all registered OAuth Clients"
}

## registerClient(): Registers a new OAuth Client with the specified client_id, client_secret, and refresh_token_validity.
function registerClient() {
    local client_id="client.$1"
    local client_secret="$2"
    local refresh_token_validity="$3"
    local user_id="$4"
    local user_passwd="$5"

    local access_token=$(getAccessToken)
    
    if [[ -z "${client_id}" || -z "${client_secret}" || -z "${refresh_token_validity}" ]]; then
        Log "FATAL" "--register requires <client_id>, <client_secret> and <refresh_token_validity>"
        showHelp
        exit 1
    fi

    local response=$( curl -s ${secureOption} -w "\n%{http_code}" \
     --request POST "${SAS_SERVICES_URL}/SASLogon/oauth/clients" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer ${access_token}" \
     -d "{
      \"client_id\": \"${client_id}\", 
      \"client_secret\": \"${client_secret}\",
      \"authorized_grant_types\": [\"urn:ietf:params:oauth:grant-type:jwt-bearer\",\"refresh_token\"],
      \"authorities\": [\"uaa.none\"],
      \"scope\": [\"openid\",\"uaa.user\"],
      \"autoapprove\": true,
      \"refresh_token_validity\": ${refresh_token_validity}
     }" )

    local http_status=$(echo "${response}" | tail -n1 | tr -d '\r')
    if [[ "$http_status" -ge 400 ]]; then
        Log "FATAL" "Failed to register OAuth Client. HTTP status: $http_status"
        echo "${response}" | head -n -1 | jq '.'
        exit 1
    fi

    local json_payload=$(echo "${response}" | head -n -1)
    local hasError=$(jq -e 'has("error")' <<< "${json_payload}" > /dev/null; echo $?)
    if [[ "$hasError" -eq 0 ]]; then
        Log "FATAL" "Client registration failed:"
        echo "${json_payload}" | jq '.'
        exit 1
    fi
    Log "INFO" "Successfully registered OAuth Client with client_id: ${client_id}"

    local admin_refresh_token=$(authorizeClient "${client_id}" "${client_secret}" "${user_id}" "${user_passwd}")
    if [[ -z "${admin_refresh_token}" ]]; then
        Log "FATAL" "Failed to obtain admin refresh token for OAuth Client with client_id: ${client_id}"
        exit 1
    fi
    Log "INFO" "Successfully authorized OAuth Client with client_id: ${client_id}"

    local admin_access_token=$(getAdminAccessToken "${client_id}" "${client_secret}" "${admin_refresh_token}")
    if [[ -z "${admin_access_token}" ]]; then
        Log "FATAL" "Failed to initialize client refresh token for client_id: ${client_id} with admin_access_token: ${admin_access_token}"
        exit 1
    fi
    Log "INFO" "Successfully obtained admin access_token for client_id: ${client_id}"


    local client_oauth_json=$(InitializeClientTokens "${client_id}" "${client_secret}" "${admin_access_token}")
    if [[ -z "${client_oauth_json}" ]]; then
        Log "FATAL" "Failed to initialize OAuth Client tokens for client_id: ${client_id}"
        exit 1
    fi
    Log "INFO" "Successfully initialized OAuth Client tokens for client_id: ${client_id}"

    if [[ "${CREATE_RECORD}" == "false" ]]; then
        Log "INFO" "Skipping creation of client JSON record as CREATE_RECORD is set to false"
    else
        writeCLientJSONRecord "${client_id}" "${client_secret}" "${client_oauth_json}"
        if [[ $? -ne 0 ]]; then
            Log "FATAL" "Failed to write client JSON record for client_id: ${client_id}"
            exit 1
        fi
        Log "INFO" "Successfully wrote client JSON record for client_id: ${client_id}"
    fi

    return 0
}

## authorizeClient() authorizes an OAuth Client using the provided client_id, client_secret, user_id, and user_passwd. 
# It returns the admin refresh token upon successful authorization. This function's outcome is similar to the OAuth interactive login flow.
function authorizeClient() {
    local client_id="$1"
    local client_secret="$2"
    local user_id="$3"
    local user_passwd="$4"
    local access_token=$(getAccessToken)

    ### NOTE TO SELF - this works, but must use the LDAP user credentials for authorization
    local response=$(curl -s ${secureOption}  -w "\n%{http_code}" \
    --request POST "${SAS_SERVICES_URL}/SASLogon/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=sas.cli" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=${user_id}" \
    --data-urlencode "password=${user_passwd}" )
    
    local refresh_token=$(echo "${response}" | head -n -1 | jq -r '.refresh_token')

    local http_status=$(echo "${response}" | tail -n1 | tr -d '\r')
    if [[ "$http_status" -ge 400 ]]; then
        Log "FATAL" "Failed to authorize OAuth Client. HTTP status: $http_status"
        echo "${response}" | head -n -1 | jq '.'
        exit 1
    fi

    local json_payload=$(echo "${response}" | head -n -1)
    local hasError=$(jq -e 'has("error")' <<< "${json_payload}" > /dev/null; echo $?)
    if [[ "$hasError" -eq 0 ]]; then
        Log "FATAL" "Client authorization failed:"
        echo "${json_payload}" | jq '.'
        exit 1
    fi    
    echo "${refresh_token}"
}

## getAdminAccessToken(): Retrieves the admin access token for an OAuth Client using the provided client_id, client_secret, and refresh_token.
function getAdminAccessToken() {
    local client_id="$1"
    local client_secret="$2"
    local refresh_token="$3"

    local response=$( curl -s ${secureOption} -w "\n%{http_code}" \
    -X POST "${SAS_SERVICES_URL}/SASLogon/oauth/token" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=sas.cli" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "response_type=token" \
    --data-urlencode "scope=openid" \
    --data-urlencode "refresh_token=${refresh_token}" | jq '.' )

    local http_status=$(echo "${response}" | tail -n1 | tr -d '\r')
    if [[ "$http_status" -ge 400 ]]; then
        Log "FATAL" "Failed to get OAuth Client Admin access_token. HTTP status: $http_status"
        echo "${response}" | head -n -1 | jq '.'
        exit 1
    fi

    local json_payload=$(echo "${response}" | head -n -1)
    local hasError=$(jq -e 'has("error")' <<< "${json_payload}" > /dev/null; echo $?)
    if [[ "$hasError" -eq 0 ]]; then
        Log "FATAL" "Failed to get OAuth Client Admin access_token:"
        echo "${json_payload}" | jq '.'
        exit 1
    fi

    local admin_access_token=$(echo "${json_payload}" | jq -r '.access_token')
    echo "${admin_access_token}"
}

## InitializeClientTokens(): Initializes the OAuth Client tokens using the provided client_id, client_secret, and admin_access_token.
function InitializeClientTokens() {
    local client_id="$1"
    local client_secret="$2"
    local admin_access_token="$3"

    local response=$( curl -s ${secureOption} -w "\n%{http_code}" \
    -X POST "${SAS_SERVICES_URL}/SASLogon/oauth/token" \
    -H "Accept: application/json" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "client_secret=${client_secret}" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "response_type=token" \
    --data-urlencode "scope=openid" \
    --data-urlencode "assertion=${admin_access_token}" |jq -r '.')

    local http_status=$(echo "${response}" | tail -n1 | tr -d '\r')
    if [[ "$http_status" -ge 400 ]]; then
        Log "FATAL" "Failed to initialize OAuth Client. HTTP status: $http_status"
        echo "${response}" | head -n -1 | jq '.'
        exit 1
    fi

    local json_payload=$(echo "${response}" | head -n -1)
    local hasError=$(jq -e 'has("error")' <<< "${json_payload}" > /dev/null; echo $?)
    if [[ "$hasError" -eq 0 ]]; then
        Log "FATAL" "Client initialization failed:"
        echo "${json_payload}" | jq '.'
        exit 1
    fi

    echo "${json_payload}" | jq '.'

}

## deleteClient(): Deletes an OAuth Client using the provided client_id.
function deleteClient() {
    local client_id="$1"
    local access_token=$(getAccessToken)

    if [[ -z "${client_id}" ]]; then
        echo "ERROR: --delete requires <client_id>"
        showHelp
        exit 1
    fi
    
    # Prevent deletion of system OAuth Clients
    case "${client_id}" in
        sas.*|sas-*|SASPy|SWAT|cas-*|dagentsrv-dev)
            echo "ERROR: Cannot delete system OAuth Client with client_id: ${client_id}"
            exit 1
            ;;
    esac

    local response=$( curl -s ${secureOption} -w "\n%{http_code}" \
    --request DELETE "${SAS_SERVICES_URL}/SASLogon/oauth/clients/${client_id}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${access_token}" )

    local http_status=$(echo "${response}" | tail -n1 | tr -d '\r')
    if [[ "$http_status" -ge 400 ]]; then
        Log "ERROR" "Failed to delete OAuth Client. HTTP status: $http_status"
        echo "${response}" | head -n -1 | jq '.'
        return 1
    fi

    local json_payload=$(echo "${response}" | head -n -1)
    local hasError=$(jq -e 'has("error")' <<< "${json_payload}" > /dev/null; echo $?)
    if [[ "$hasError" -eq 0 ]]; then
        Log "FATAL" "Failed to delete OAuth Client with client_id: ${client_id}:"
        echo "${json_payload}" | jq '.'
        return 1
    fi
  
    return 0
}

## listClients(): Lists all non-system OAuth Clients.
function listClients() {
    local access_token=$(getAccessToken)
    local response=$( curl -s ${secureOption} -w "\n%{http_code}" \
    --request GET "${SAS_SERVICES_URL}/SASLogon/oauth/clients?limit=999999" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${access_token}" )

    local http_status=$(echo "${response}" | tail -n1 | tr -d '\r')
    if [[ "$http_status" -ge 400 ]]; then
        Log "ERROR" "Failed to list OAuth Clients. HTTP status: $http_status"
        echo "${response}" | head -n -1 | jq '.'
        return 1
    fi

    local json_payload=$(echo "${response}" | head -n -1)
    local hasError=$(jq -e 'has("error")' <<< "${json_payload}" > /dev/null; echo $?)
    if [[ "$hasError" -eq 0 ]]; then
        Log "FATAL" "Failed to list OAuth Clients:"
        echo "${json_payload}" | jq '.'
        return 1
    fi
  
    echo "${json_payload}" | jq '.resources[] | select(.client_id | test("^(sas|SASPy|SWAT|cas|dagent)") | not) | .client_id'
}

function writeCLientJSONRecord() {
    local client_id="$1"
    local client_secret="$2"
    local client_oauth_json="$3"

    local refresh_token=$(jq -r '.refresh_token' <<< "${client_oauth_json}")
    local refresh_expires_in=$(jq -r '.refresh_expires_in' <<< "${client_oauth_json}")
    
    if [[ ${CREATE_RECORD} == "true" ]]; then
        # WARNING This will create a file with the details about the client secrets and refresh token for the secrets manager.
        # Ensure that this file is handled securely.
        jq -n \
            --arg id "$client_id" \
            --arg secret "$client_secret" \
            --arg token "$refresh_token" \
            --arg expires_in "$refresh_expires_in" \
            '{client_id: $id, client_secret: $secret, refresh_token: $token, refresh_expires_in: $expires_in}' \
            > "tmp/${client_id}-secrets.json"
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Failed to create secrets JSON file for client_id: ${client_id}"
            return 1
        fi
    fi    
}



function parseArgs() {
    local cmd="$1"
    shift
    
    # Initialize GLOBAL variables (uppercase)
    CLIENT_ID=""
    CLIENT_SECRET=""
    REFRESH_TOKEN_VALIDITY=""
    USER_ID=""
    USER_PASSWD=""
    
    # Parse named parameters
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --client-id) CLIENT_ID="$2"; shift 2 ;;
            --client-secret) CLIENT_SECRET="$2"; shift 2 ;;
            --refresh-token-validity) REFRESH_TOKEN_VALIDITY="$2"; shift 2 ;;
            --user-id) USER_ID="$2"; shift 2 ;;
            --user-passwd) USER_PASSWD="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
}


function main() {

    # Check if at least one argument is provided
    if [[ $# -lt 1 ]]; then
        showHelp
        exit 1
    fi

    # Parse command-line arguments for secure option
    local cmd_args=()
    for arg in "$@"; do
        case "$arg" in
            --insecure|-k) secureOption="-k"; shift ;;
            *) cmd_args+=("$arg") ;;
        esac
    done

    # Validate the Viya CLI setup - will exit script if it fails
    validateCLISetup > /dev/null 2>&1
    if [[ "$?" -ne 0 ]]; then
        Log "ERROR" "Viya CLI validation failed. Please check your Viya CLI installation and configuration."
        exit 1
    fi

    # Get the SAS services URL - will exit script if it fails to retrieve it
    SAS_SERVICES_URL=$(getUrlRoot)
    if [[ "$?" -ne 0 ]]; then
        Log "ERROR" "Failed to get SAS services URL."
        Log "ERROR" "Please make sure your Viya CLI is properly configured and you have network connectivity to the SAS services."
        exit 1
    fi


    if [[ ! -d "tmp" ]]; then
        Log "INFO" "tmp folder not found. Creating tmp folder."
        mkdir -p "tmp"
    fi

    if [[ ! -d "log" ]]; then
        Log "INFO" "log folder not found. Creating log folder."
        mkdir -p "log"
    fi


    case "${cmd_args[0]}" in
        register)
            parseArgs "--register" "${cmd_args[@]:1}"
            if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" || -z "$REFRESH_TOKEN_VALIDITY" || -z "$USER_ID" || -z "$USER_PASSWD" ]]; then
                Log "ERROR" "--register requires --client_id, --client_secret, --refresh_token_validity, --user_id, and --user_passwd"
                showHelp
                exit 1
            fi
            registerClient "$CLIENT_ID" "$CLIENT_SECRET" "$REFRESH_TOKEN_VALIDITY" "$USER_ID" "$USER_PASSWD"
            ;;
        delete)
            parseArgs "--delete" "${cmd_args[@]:1}"
            if [[ -z "$CLIENT_ID" ]]; then
                Log "ERROR" "--delete requires --client_id"
                showHelp
                exit 1
            fi
            Log "WARNING" "******************************************************************"
            Log "WARNING" "*"
            Log "WARNING" "Deleting OAuth Client: ${CLIENT_ID} is IRREVERSIBLE!!!"
            Log "WARNING" "*"
            Log "WARNING" "******************************************************************"
            echo "Do you want to continue?"
            read -p "Type 'yes' to confirm: " confirmation
            if [[ "$confirmation" == "yes" ]]; then
                deleteClient "$CLIENT_ID"
            else
                Log "INFO" "Deletion aborted by user."
            fi
            ;;
        list)
            local ls=$(listClients)
            Log "INFO" "Successfully retrieved list of OAuth Clients"
            echo "$ls"
            ;;
        *)
            showHelp
            exit 1
            ;;
    esac
}

main "$@"