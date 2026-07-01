#!/bin/bash
# Shared credential parsing and inventory injection for RHOSO deploy scripts.

_cred_yaml_value() {
    local key="$1"
    local file="$2"
    grep "^${key}:" "$file" 2>/dev/null | head -1 | sed -E "s/^${key}: *[\"']?([^\"']*)[\"']?/\\1/"
}

_cred_yaml_bool() {
    local val
    val=$(_cred_yaml_value "$1" "$2")
    if [[ -z "$val" ]]; then
        echo "false"
    else
        echo "$val" | tr '[:upper:]' '[:lower:]'
    fi
}

_inject_inventory_var() {
    local inventory_file="$1"
    local key="$2"
    local value="$3"
    python3 - "$key" "$value" "$inventory_file" <<'PY'
import re
import sys

key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
pattern = re.compile(rf"^(\s*{re.escape(key)}:).*$")
with open(path, encoding="utf-8") as handle:
    lines = handle.readlines()
with open(path, "w", encoding="utf-8") as handle:
    for line in lines:
        match = pattern.match(line)
        if match:
            handle.write(f'{match.group(1)} "{value}"\n')
        else:
            handle.write(line)
PY
}

_inject_inventory_bool() {
    local inventory_file="$1"
    local key="$2"
    local value="$3"
    python3 - "$key" "$value" "$inventory_file" <<'PY'
import re
import sys

key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
pattern = re.compile(rf"^(\s*{re.escape(key)}:).*$")
with open(path, encoding="utf-8") as handle:
    lines = handle.readlines()
with open(path, "w", encoding="utf-8") as handle:
    for line in lines:
        match = pattern.match(line)
        if match:
            handle.write(f"{match.group(1)} {value}\n")
        else:
            handle.write(line)
PY
}

# Parse credentials.yml and export CRED_* variables.
# Sets CRED_SUBSCRIPTION_MODE to "satellite" or "portal".
parse_credentials_file() {
    local credentials_file="$1"

    if [[ ! -f "$credentials_file" ]]; then
        echo "[ERROR] Credentials file not found: $credentials_file" >&2
        exit 1
    fi

    echo "[INFO] Loading credentials from: $credentials_file"

    export CRED_REGISTRY_USERNAME=$(_cred_yaml_value registry_username "$credentials_file")
    export CRED_REGISTRY_PASSWORD=$(_cred_yaml_value registry_password "$credentials_file")
    export CRED_RHC_USERNAME=$(_cred_yaml_value rhc_username "$credentials_file")
    export CRED_RHC_PASSWORD=$(_cred_yaml_value rhc_password "$credentials_file")
    export CRED_SATELLITE_URL=$(_cred_yaml_value satellite_url "$credentials_file")
    export CRED_SATELLITE_ORG=$(_cred_yaml_value satellite_org "$credentials_file")
    export CRED_RHC_ACTIVATION_KEY=$(_cred_yaml_value ocp4_workload_rhoso_deployment_rhc_activation_key "$credentials_file")
    export CRED_SATELLITE_INSECURE=$(_cred_yaml_bool satellite_insecure "$credentials_file")

    if [[ -z "$CRED_REGISTRY_USERNAME" || -z "$CRED_REGISTRY_PASSWORD" ]]; then
        echo "[ERROR] Missing required registry credentials in file: $credentials_file" >&2
        echo "Required fields: registry_username, registry_password" >&2
        exit 1
    fi

    local portal_mode=false
    local satellite_mode=false

    if [[ -n "$CRED_RHC_USERNAME" && -n "$CRED_RHC_PASSWORD" ]]; then
        portal_mode=true
    fi
    if [[ -n "$CRED_SATELLITE_URL" ]]; then
        satellite_mode=true
    fi

    if [[ "$portal_mode" == true && "$satellite_mode" == true ]]; then
        echo "[ERROR] Conflicting subscription credentials in file: $credentials_file" >&2
        echo "Use either Customer Portal (rhc_username + rhc_password) OR Satellite" >&2
        echo "(satellite_url + satellite_org + ocp4_workload_rhoso_deployment_rhc_activation_key), not both." >&2
        exit 1
    fi

    if [[ "$satellite_mode" == true ]]; then
        if [[ -z "$CRED_SATELLITE_ORG" || -z "$CRED_RHC_ACTIVATION_KEY" ]]; then
            echo "[ERROR] Incomplete Satellite credentials in file: $credentials_file" >&2
            echo "Satellite mode requires: satellite_url, satellite_org," >&2
            echo "ocp4_workload_rhoso_deployment_rhc_activation_key" >&2
            exit 1
        fi
        export CRED_SUBSCRIPTION_MODE=satellite
        export CRED_RHC_USERNAME=""
        export CRED_RHC_PASSWORD=""
    elif [[ "$portal_mode" == true ]]; then
        export CRED_SUBSCRIPTION_MODE=portal
    else
        echo "[ERROR] Missing subscription credentials in file: $credentials_file" >&2
        echo "Provide either Customer Portal (rhc_username + rhc_password) or Satellite" >&2
        echo "(satellite_url + satellite_org + ocp4_workload_rhoso_deployment_rhc_activation_key)." >&2
        exit 1
    fi

    echo "[INFO] Credentials loaded successfully"
    echo "[INFO] Registry username: ${CRED_REGISTRY_USERNAME%%|*}|***"
    echo "[INFO] Subscription mode: $CRED_SUBSCRIPTION_MODE"
    if [[ "$CRED_SUBSCRIPTION_MODE" == portal ]]; then
        echo "[INFO] RHC username: $CRED_RHC_USERNAME"
    else
        echo "[INFO] Satellite URL: $CRED_SATELLITE_URL"
        echo "[INFO] Satellite org: $CRED_SATELLITE_ORG"
    fi
}

# Inject parsed credentials into an inventory file (in-place).
inject_credentials_into_inventory() {
    local inventory_file="$1"

    if [[ ! -f "$inventory_file" ]]; then
        echo "[ERROR] Inventory file not found: $inventory_file" >&2
        exit 1
    fi

    if [[ -z "${CRED_REGISTRY_USERNAME:-}" ]]; then
        return 0
    fi

    echo "[INFO] Injecting credentials into inventory: $inventory_file"

    _inject_inventory_var "$inventory_file" registry_username "$CRED_REGISTRY_USERNAME"
    _inject_inventory_var "$inventory_file" registry_password "$CRED_REGISTRY_PASSWORD"

    if [[ "${CRED_SUBSCRIPTION_MODE:-}" == satellite ]]; then
        _inject_inventory_var "$inventory_file" satellite_url "$CRED_SATELLITE_URL"
        _inject_inventory_var "$inventory_file" satellite_org "$CRED_SATELLITE_ORG"
        _inject_inventory_var "$inventory_file" ocp4_workload_rhoso_deployment_rhc_activation_key "$CRED_RHC_ACTIVATION_KEY"
        _inject_inventory_bool "$inventory_file" satellite_insecure "$CRED_SATELLITE_INSECURE"
        _inject_inventory_var "$inventory_file" rhc_username ""
        _inject_inventory_var "$inventory_file" rhc_password ""
    else
        _inject_inventory_var "$inventory_file" rhc_username "$CRED_RHC_USERNAME"
        _inject_inventory_var "$inventory_file" rhc_password "$CRED_RHC_PASSWORD"
        _inject_inventory_var "$inventory_file" satellite_url ""
        _inject_inventory_var "$inventory_file" satellite_org ""
        _inject_inventory_var "$inventory_file" ocp4_workload_rhoso_deployment_rhc_activation_key ""
        _inject_inventory_bool "$inventory_file" satellite_insecure false
    fi

    echo "[INFO] Credentials injected into inventory"
}
