#!/bin/bash

########################################################################################################################
# Retrieve and return SSM parameter or AWS Secrets value.
#
# Arguments
#   $1 -> SSM key path
#
#  Returns
#   0 on success; 1 if the aws ssm call fails or the key does not exist.
########################################################################################################################
get_ssm_value() {
  local ssm_key="$1"

  if ! ssm_value="$(aws ssm --region "${REGION}"  get-parameters \
    --names "${ssm_key%#*}" \
    --query 'Parameters[*].Value' \
    --with-decryption \
    --output text)"; then
      echo "$ssm_value"
      return 1
  fi

  if test -z "${ssm_value}"; then
    echo "Unable to find SSM path '${ssm_key%#*}'"
    return 1
  fi

  if [[ "$ssm_key" == *"secretsmanager"* ]]; then
    # grep for the value of the secrets manager object's key
    # the object's key is the string following the '#' in the ssm_key variable
    echo "${ssm_value}" | grep -Eo "${ssm_key#*#}[^,]*" | grep -Eo "[^:]*$"
  else
    echo "${ssm_value}"
  fi
}

########################################################################################################################
# Set a given variable name based on an SSM prefix and suffix. If SSM exists, the ssm_template will
# be used to set the value. If the SSM prefix is 'unused', no value is set and SSM isn't checked.
########################################################################################################################
set_templated_var() {
  local var_name="${1}"
  local var_value="${!1}"
  local ssm_prefix="${2}"
  local ssm_suffix="${3}"
  local ssm_template="${4}"

  if [[ ${var_value} != '' ]]; then
    echo "${var_name} already set to '${var_value}'"
    return
  elif [[ ${ssm_prefix} != "unused" ]]; then
    echo "${var_name} is not set, trying to find it in SSM..."
    if ! ssm_value=$(get_ssm_value "${ssm_prefix}/${ssm_suffix}"); then
      echo "WARN: Issue fetching SSM path '${ssm_prefix}/${ssm_suffix}' - ${ssm_value}...
            Continuing as this could be a disabled environment"
    else
      echo "Found '${ssm_prefix}/${ssm_suffix}' in SSM"
      # Substitue ssm_value within the supplied ssm template
      var_value=$(echo "${ssm_template}" | ssm_value=${ssm_value} envsubst)
    fi
  else
    echo "Not fetching SSM - it is set to 'unused'"
  fi

  # Always export the variable and value
  echo "Setting '${var_name}' to '${var_value}'"
  export "${var_name}=${var_value}"
}
