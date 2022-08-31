#!/bin/bash

########################################################################################################################
#
# This script may be used to set up a development or test environment to verify the Kubernetes and Kustomization yaml
# files either in their present form or after making some local changes to them.
#
# Run the script in the following manner:
#     source <your-env-variables-file>; CONFIG_REPO_BRANCH=$(git rev-parse --abbrev-ref HEAD) ./dev-env.sh
#
# ------------
# Requirements
# ------------
# The script requires the following tools to be installed:
#   - openssl
#   - base64
#   - kustomize
#   - kubectl
#   - envsubst
#
# In addition, the assumption is that kubectl is configured to authenticate and apply manifests to the Kubernetes
# cluster. For EKS clusters, this requires an AWS key and secret with the appropriate IAM policies to be configured and
# requires that the aws CLI tool and probably the aws-iam-authenticator CLI tool are installed.
#
# ------------------
# Usage instructions
# ------------------
# Aside from a -n (dry-run option), the script does not take any parameters but rather acts on environment variables.
# The environment variables will be substituted into the variables in the yaml template files.
#
# Both real and dry run will emit the Kubernetes manifest file for the entire deployment into the file /tmp/deploy.yaml.
# After running the script in dry-run mode, the deploy.yaml file may be edited, if desired, but it should be able to
# be deployed as-is onto the cluster. In fact, this is exactly what gets deployed when the script is run in real
# mode, i.e. without the -n option.
#
# The following environment variables, if present, will be used for the following purposes:
#
# ----------------------------------------------------------------------------------------------------------------------
# Variable                  | Purpose                                            | Default (if not present)
# ----------------------------------------------------------------------------------------------------------------------
# TENANT_NAME               | The name of the tenant, e.g. k8s-icecream. If      | PingPOC
#                           | provided, this value will be used for the cluster  |
#                           | name and must have the correct case (e.g. PingPOC  |
#                           | vs. pingpoc). If not provided, this variable is    |
#                           | not used, and the cluster name defaults to the CDE |
#                           | name. On AWS, the cluster name is a required       |
#                           | parameter to Container Insights, an AWS-specific   |
#                           | logging and monitoring solution, and cluster       |
#                           | autoscaler, which is used for automatic scaling of |
#                           | of Kubernetes worker nodes.                        |
#                           |                                                    |
# ENVIRONMENT               | An environment to isolate the Ping stack into its  | The value of the USER environment
#                           | own namespace within the Kubernetes cluster. The   | variable.
#                           | Ping stack is generally deployed to a namespace    |
#                           | called "ping-cloud". But if ENVIRONMENT is set, it |
#                           | is used as a name suffix. For example, if it is    |
#                           | set to "staging", then the namespace will be       |
#                           | "ping-cloud-staging". This variable is useful not  |
#                           | just in a shared multi-tenant Kubernetes cluster   |
#                           | but could also be used to create multiple Ping     |
#                           | stacks within the same cluster for testing         |
#                           | purposes. It may be set to an empty string in      |
#                           | which case, the namespace used for the Ping stack  |
#                           | will be "ping-cloud-$USER".                        |
#                           |                                                    |
# TENANT_DOMAIN             | The tenant's domain, e.g. us1.poc.ping.cloud       | us1.poc.ping.cloud
#                           |                                                    |
# GLOBAL_TENANT_DOMAIN      | Region-independent URL used for DNS failover/      | Replaces the first segment of
#                           | routing.                                           | the TENANT_DOMAIN value with the
#                           |                                                    | string "global". For example, it will
#                           |                                                    | default to "global.poc.ping.com" for
#                           |                                                    | tenant domain "us1.poc.ping.cloud".
#                           |                                                    |
# REGION                    | The region where the tenant environment is         | us-east-2
#                           | deployed. On AWS, this is a required parameter     |
#                           | to Container Insights, an AWS-specific logging     |
#                           | and monitoring solution.                           |
#                           |                                                    |
# REGION_NICK_NAME          | An optional nick name for the region. For example, | Same as REGION.
#                           | this variable may be set to a unique name in       |
#                           | multi-cluster deployments which live in the same   |
#                           | region. The nick name will be used as the name of  |
#                           | the region-specific code directory in the cluster  |
#                           | state repo.                                        |
#                           |                                                    |
# IS_MULTI_CLUSTER          | Flag indicating whether or not this is a           | false
#                           | multi-cluster deployment.                          |
#                           |                                                    |
# TOPOLOGY_DESCRIPTOR_FILE  | An optional file that may be provided in           | No default. If not provided, a
#                           | multi-cluster dev environments. This file must     | descriptor file containing the
#                           | specify the region and the hostname to use for     | server in the local cluster will
#                           | cluster communication and the number of replicas   | be created and used.
#                           | in that region. A sample file is provided in the   |
#                           | pingdirectory profiles under profiles/aws/         |
#                           | pingdirectory/topology/descriptor.json.sample.     |
#                           | This file will be mounted into the Ping containers |
#                           | at /opt/staging/topology/descriptor.json.          |
#                           |                                                    |
# PRIMARY_TENANT_DOMAIN     | The tenant's domain in the primary region.         | Same as TENANT_DOMAIN.
#                           | Only used if IS_MULTI_CLUSTER is true.             |
#                           |                                                    |
# PRIMARY_REGION            | The region where the tenant's primary environment  | Same as REGION.
#                           | is deployed. On AWS, this is a required parameter  |
#                           | to Container Insights, an AWS-specific logging     |
#                           | and monitoring solution.                           |
#                           | Only used if IS_MULTI_CLUSTER is true.             |
#                           |                                                    |
# SECONDARY_TENANT_DOMAINS  | A comma-separated list of tenant domains of the    | No default.
#                           | secondary regions in multi-region environments,    |
#                           | e.g. "mini.ping-demo.com,mini.ping-oasis.com".     |
#                           | Only used if IS_MULTI_CLUSTER is true.             |
#                           |                                                    |
# CONFIG_REPO_BRANCH        | The branch within this repository for server       | master
#                           | profiles, i.e. configuration.                      |
#                           |                                                    |
# CONFIG_PARENT_DIR         | The parent directory for server profiles within    | aws
#                           | the "profiles" base directory, e.g. dev, aws, etc. |
#                           |                                                    |
# ARTIFACT_REPO_URL         | The URL for private plugins (e.g. PF kits, PD      | The string "unused".
#                           | extensions). If not provided, the Ping stack will  |
#                           | be provisioned without private plugins. This URL   |
#                           | must use an s3 scheme, e.g.                        |
#                           | s3://customer-repo-bucket-name.                    |
#                           |                                                    |
# PING_ARTIFACT_REPO_URL    | This environment variable can be used to overwrite | https://ping-artifacts.s3-us-west-2.amazonaws.com
#                           | the default endpoint for public plugins. This URL  |
#                           | must use an https scheme as shown by the default   |
#                           | value.                                             |
#                           |                                                    |
# LOG_ARCHIVE_URL           | The URL of the log archives. If provided, logs     | The string "unused"
#                           | are periodically captured and sent to this URL.    |
#                           |                                                    |
# BACKUP_URL                | The URL of the backup location. If provided, data  | The string "unused".
#                           | backups are periodically captured and sent to this |
#                           | URL. For AWS S3 buckets, it must be an S3 URL,     |
#                           | e.g. s3://backups.                                 |
#                           |                                                    |
# PLATFORM_EVENT_QUEUE_NAME | The name of the queue that may be used to notify   | v2_platform_event_queue.fifo
#                           | PingCloud applications of platform events. This    |
#                           | is currently only used if the orchestrator for     |
#                           | PingCloud environments is MyPing.                  |
#                           |                                                    |
# ORCH_API_SSM_PATH_PREFIX  | The prefix of the SSM path that contains MyPing    | /pcpt/orch-api
#                           | state data required for the P14C/P1AS integration. |
#                           |                                                    |
# SERVICE_SSM_PATH_PREFIX   | The prefix of the SSM path that contains Services  |
#                           | data for the cluster                               | /pcpt/service
#                           |                                                    |
# DEPLOY_FILE               | The name of the file where the final deployment    | /tmp/deploy.yaml
#                           | spec is saved before applying it.                  |
#                           |                                                    |
# K8S_CONTEXT               | The current Kubernetes context, i.e. cluster.      | The current context as set in
#                           | spec is saved before applying it.                  | ~/.kube/config or the config file
#                           |                                                    | to which KUBECONFIG is set.
#                           |                                                    |
# NEW_RELIC_LICENSE_KEY     | The key of NewRelic APM Agent used to send data to | The SSM path: ssm://pcpt/sre/new-relic/java-agent-license-key
#                           | NewRelic account                                   |
#                           |                                                    |
# MYSQL_SERVICE_HOST        | The hostname of the MySQL database server.         | beluga-ci-cd-mysql.cmpxy5bpieb9.us-west-2.rds.amazonaws.com
#                           |                                                    |
# MYSQL_USER                | The DBA user of the PingCentral MySQL RDS          | The SSM path:
#                           | database.                                          | ssm://aws/reference/secretsmanager//pcpt/ping-central/dbserver#username
#                           |                                                    |
# MYSQL_PASSWORD            | The DBA password of the PingCentral MySQL RDS      | The SSM path:
#                           | database.                                          | ssm://aws/reference/secretsmanager//pcpt/ping-central/dbserver#password
#                           |                                                    |
# PING_IDENTITY_DEVOPS_USER | A user with license to run Ping Software.          | The SSM path:
#                           |                                                    | ssm://pcpt/devops-license/user
#                           |                                                    |
# PING_IDENTITY_DEVOPS_KEY  | The key to the above user.                         | The SSM path:
#                           |                                                    | ssm://pcpt/devops-license/key
#                           |                                                    |
# LEGACY_LOGGING            | Flag indicating where we should send app logs -    | True
#                           | to CloudWatch(if True) or to ELK (if False)        |
########################################################################################################################

#
# Ensure we're in the correct directory to run the script.
#
declare -r homeDir=$(dirname ${0})
pushd ${homeDir} > /dev/null 2>&1

# Source devops and aws-eks files, if present
test -f ~/.pingidentity/devops && . ~/.pingidentity/devops

# Source some utility methods.
. utils.sh

declare dryrun='false'
declare skipTest='false'

LOG_FILE=/tmp/dev-env.log
rm -f "${LOG_FILE}"

# Parse Parameters
while getopts 'ns' OPTION
do
  case ${OPTION} in
    n)
      dryrun='true'
      ;;
    s)
      skipTest='true'
      ;;
    *)
      echo "Usage ${0} [ -ns ] n = dry-run; s = skip-test"
      popd  > /dev/null 2>&1
      exit 1
      ;;
  esac
done

# We assume we always run dev-env.sh from the top-level of the repo
CUR_DIR=$(pwd)

# Checking required tools and environment variables.
check_binaries "openssl" "base64" "kustomize" "kubectl" "envsubst"
HAS_REQUIRED_TOOLS=${?}

if test ${HAS_REQUIRED_TOOLS} -ne 0; then
  popd  > /dev/null 2>&1
  exit 1
fi

test -z "${IS_MULTI_CLUSTER}" && IS_MULTI_CLUSTER=false
if "${IS_MULTI_CLUSTER}"; then
  if test ! "${SECONDARY_TENANT_DOMAINS}"; then
    echo 'In multi-cluster mode SECONDARY_TENANT_DOMAINS must be set.'
    popd > /dev/null 2>&1
    exit 1
  fi
fi

# Show initial values for relevant environment variables.
log "Initial TENANT_NAME: ${TENANT_NAME}"
log "Initial ENVIRONMENT: ${ENVIRONMENT}"

log "Initial IS_MULTI_CLUSTER: ${IS_MULTI_CLUSTER}"
log "Initial TOPOLOGY_DESCRIPTOR_FILE: ${TOPOLOGY_DESCRIPTOR_FILE}"
log "Initial PLATFORM_EVENT_QUEUE_NAME: ${PLATFORM_EVENT_QUEUE_NAME}"
log "Initial ORCH_API_SSM_PATH_PREFIX: ${ORCH_API_SSM_PATH_PREFIX}"
log "Initial SERVICE_SSM_PATH_PREFIX: ${SERVICE_SSM_PATH_PREFIX}"
log "Initial REGION: ${REGION}"
log "Initial REGION_NICK_NAME: ${REGION_NICK_NAME}"
log "Initial PRIMARY_REGION: ${PRIMARY_REGION}"
log "Initial TENANT_DOMAIN: ${TENANT_DOMAIN}"
log "Initial PRIMARY_TENANT_DOMAIN: ${PRIMARY_TENANT_DOMAIN}"
log "Initial SECONDARY_TENANT_DOMAINS: ${SECONDARY_TENANT_DOMAINS}"
log "Initial GLOBAL_TENANT_DOMAIN: ${GLOBAL_TENANT_DOMAIN}"

log "Initial CONFIG_REPO_BRANCH: ${CONFIG_REPO_BRANCH}"
log "Initial CONFIG_PARENT_DIR: ${CONFIG_PARENT_DIR}"

log "Initial ARTIFACT_REPO_URL: ${ARTIFACT_REPO_URL}"
log "Initial PING_ARTIFACT_REPO_URL: ${PING_ARTIFACT_REPO_URL}"
log "Initial LOG_ARCHIVE_URL: ${LOG_ARCHIVE_URL}"
log "Initial BACKUP_URL: ${BACKUP_URL}"

log "Initial MYSQL_SERVICE_HOST: ${MYSQL_SERVICE_HOST}"
log "Initial MYSQL_USER: ${MYSQL_USER}"
log "Initial MYSQL_PASSWORD: ${MYSQL_PASSWORD}"

log "Initial LEGACY_LOGGING: ${LEGACY_LOGGING}"

log "Initial PING_IDENTITY_DEVOPS_USER: ${PING_IDENTITY_DEVOPS_USER}"

log "Initial DEPLOY_FILE: ${DEPLOY_FILE}"
log "Initial K8S_CONTEXT: ${K8S_CONTEXT}"
log ---

# A script that may be used to set up a dev/test environment against the
# current cluster. Must have the GTE devops user and key exported as
# environment variables.
export TENANT_NAME="${TENANT_NAME:-PingPOC}"

export ENVIRONMENT=-"${ENVIRONMENT:-${USER}}"
export BELUGA_ENV_NAME="${ENVIRONMENT#-}"

export IS_MULTI_CLUSTER="${IS_MULTI_CLUSTER}"

export PLATFORM_EVENT_QUEUE_NAME="${PLATFORM_EVENT_QUEUE_NAME:-v2_platform_event_queue.fifo}"
export ORCH_API_SSM_PATH_PREFIX="${ORCH_API_SSM_PATH_PREFIX:-/pcpt/orch-api}"
export SERVICE_SSM_PATH_PREFIX="${SERVICE_SSM_PATH_PREFIX:-/${TENANT_NAME}/pcpt/service}"

export REGION="${REGION:-us-east-2}"
export REGION_NICK_NAME="${REGION_NICK_NAME:-${REGION}}"
export PRIMARY_REGION="${PRIMARY_REGION:-${REGION}}"

export TENANT_DOMAIN="${TENANT_DOMAIN:-us1.poc.ping.cloud}"
export PRIMARY_TENANT_DOMAIN="${PRIMARY_TENANT_DOMAIN:-${TENANT_DOMAIN}}"
export SECONDARY_TENANT_DOMAINS="${SECONDARY_TENANT_DOMAINS}"
export GLOBAL_TENANT_DOMAIN="${GLOBAL_TENANT_DOMAIN:-$(echo "${TENANT_DOMAIN}"|sed -e "s/[^.]*.\(.*\)/global.\1/")}"

export CONFIG_REPO_BRANCH="${CONFIG_REPO_BRANCH:-master}"
export CONFIG_PARENT_DIR="${CONFIG_PARENT_DIR:-aws}"

export ARTIFACT_REPO_URL="${ARTIFACT_REPO_URL:-unused}"
export PING_ARTIFACT_REPO_URL="${PING_ARTIFACT_REPO_URL:-https://ping-artifacts.s3-us-west-2.amazonaws.com}"
export LOG_ARCHIVE_URL="${LOG_ARCHIVE_URL:-unused}"
export BACKUP_URL="${BACKUP_URL:-unused}"

export MYSQL_SERVICE_HOST="${MYSQL_SERVICE_HOST:-beluga-ci-cd-mysql.cmpxy5bpieb9.us-west-2.rds.amazonaws.com}"
export MYSQL_USER="${MYSQL_USER:-ssm://aws/reference/secretsmanager//pcpt/ping-central/dbserver#username}"
export MYSQL_PASSWORD="${MYSQL_PASSWORD:-ssm://aws/reference/secretsmanager//pcpt/ping-central/dbserver#password}"

export PING_IDENTITY_DEVOPS_USER="${PING_IDENTITY_DEVOPS_USER:-ssm://pcpt/devops-license/user}"
export PING_IDENTITY_DEVOPS_KEY="${PING_IDENTITY_DEVOPS_KEY:-ssm://pcpt/devops-license/key}"

export LEGACY_LOGGING="${LEGACY_LOGGING:-True}"

# MySQL database names cannot have dashes. So transform dashes into underscores.
ENV_NAME_NO_DASHES=$(echo ${BELUGA_ENV_NAME} | tr '-' '_')
export MYSQL_DATABASE="pingcentral_${ENV_NAME_NO_DASHES}"

DEPLOY_FILE=${DEPLOY_FILE:-/tmp/deploy.yaml}
test -z "${K8S_CONTEXT}" && K8S_CONTEXT=$(kubectl config current-context)

# Show the values being used for the relevant environment variables.
log "Using TENANT_NAME: ${TENANT_NAME}"
log "Using ENVIRONMENT: ${BELUGA_ENV_NAME}"

log "Using IS_MULTI_CLUSTER: ${IS_MULTI_CLUSTER}"
log "Using TOPOLOGY_DESCRIPTOR_FILE: ${TOPOLOGY_DESCRIPTOR_FILE}"
log "Using PLATFORM_EVENT_QUEUE_NAME: ${PLATFORM_EVENT_QUEUE_NAME}"
log "Using ORCH_API_SSM_PATH_PREFIX: ${ORCH_API_SSM_PATH_PREFIX}"
log "Using SERVICE_SSM_PATH_PREFIX: ${SERVICE_SSM_PATH_PREFIX}"
log "Using REGION: ${REGION}"
log "Using REGION_NICK_NAME: ${REGION_NICK_NAME}"
log "Using PRIMARY_REGION: ${PRIMARY_REGION}"
log "Using TENANT_DOMAIN: ${TENANT_DOMAIN}"
log "Using PRIMARY_TENANT_DOMAIN: ${PRIMARY_TENANT_DOMAIN}"
log "Using SECONDARY_TENANT_DOMAINS: ${SECONDARY_TENANT_DOMAINS}"
log "Using GLOBAL_TENANT_DOMAIN: ${GLOBAL_TENANT_DOMAIN}"

log "Using CONFIG_REPO_BRANCH: ${CONFIG_REPO_BRANCH}"
log "Using CONFIG_PARENT_DIR: ${CONFIG_PARENT_DIR}"

log "Using ARTIFACT_REPO_URL: ${ARTIFACT_REPO_URL}"
log "Using PING_ARTIFACT_REPO_URL: ${PING_ARTIFACT_REPO_URL}"
log "Using LOG_ARCHIVE_URL: ${LOG_ARCHIVE_URL}"
log "Using BACKUP_URL: ${BACKUP_URL}"

log "Using MYSQL_SERVICE_HOST: ${MYSQL_SERVICE_HOST}"
log "Using MYSQL_USER: ${MYSQL_USER}"
log "Using MYSQL_PASSWORD: ${MYSQL_PASSWORD}"
log "Using MYSQL_DATABASE: ${MYSQL_DATABASE}"

log "Using PING_IDENTITY_DEVOPS_USER: ${PING_IDENTITY_DEVOPS_USER}"

log "Using LEGACY_LOGGING: ${LEGACY_LOGGING}"

log "Using DEPLOY_FILE: ${DEPLOY_FILE}"
log "Using K8S_CONTEXT: ${K8S_CONTEXT}"
log ---

NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-ssm://pcpt/sre/new-relic/java-agent-license-key}"
if [[ ${NEW_RELIC_LICENSE_KEY} == "ssm://"* ]]; then
  if ! ssm_value=$(get_ssm_value "${NEW_RELIC_LICENSE_KEY#ssm:/}"); then
    echo "Warn: ${ssm_value}"
    echo "Setting NEW_RELIC_LICENSE_KEY to unused"
    NEW_RELIC_LICENSE_KEY="unused"
  else
    NEW_RELIC_LICENSE_KEY="${ssm_value}"
  fi
fi
export DATASYNC_P1AS_SYNC_SERVER=${DATASYNC_P1AS_SYNC_SERVER:-"pingdirectory-0"}

export NEW_RELIC_LICENSE_KEY_BASE64=$(base64_no_newlines "${NEW_RELIC_LICENSE_KEY}")
export CLUSTER_NAME=${TENANT_NAME}
export CLUSTER_NAME_LC=$(echo ${CLUSTER_NAME} | tr '[:upper:]' '[:lower:]')

export NAMESPACE=ping-cloud-${BELUGA_ENV_NAME}

export NEW_RELIC_ENVIRONMENT_NAME=${TENANT_NAME}_${BELUGA_ENV_NAME}_${REGION}_k8s-cluster

# Set the cluster type based on primary or secondary.
"${IS_MULTI_CLUSTER}" && test "${TENANT_DOMAIN}" != "${PRIMARY_TENANT_DOMAIN}" &&
  CLUSTER_TYPE=secondary ||
  CLUSTER_TYPE=

if "${IS_MULTI_CLUSTER}"; then
  test "${TENANT_DOMAIN}" != "${PRIMARY_TENANT_DOMAIN}" && CLUSTER_TYPE=secondary
  if test -f "${TOPOLOGY_DESCRIPTOR_FILE}"; then
    export TOPOLOGY_DESCRIPTOR=$(tr -d '[:space:]' < "${TOPOLOGY_DESCRIPTOR_FILE}")
  else
    log "WARNING!!! TOPOLOGY_DESCRIPTOR_FILE not provided or does not exist in multi-cluster mode"
    log "WARNING!!! Only the servers in the local cluster will be considered part of the topology"
    echo ---
  fi
fi

build_dev_deploy_file "${DEPLOY_FILE}" "${CLUSTER_TYPE}"

if test "${dryrun}" = 'false'; then

  log "Deploying ${DEPLOY_FILE} to cluster ${CLUSTER_NAME}, namespace ${NAMESPACE} for tenant ${TENANT_DOMAIN}"
  kubectl apply -f "${DEPLOY_FILE}" --context "${K8S_CONTEXT}" | tee -a "${LOG_FILE}"

  if [[ "${PIPESTATUS[0]}" != 0 ]]; then
    echo -e "\033[31m->>>> Non-zero exit code while applying changes to cluster ^^^^^\033[0m"
    exit 1
  else
    echo -e "\033[32m^^^^^^ SUCCESS! kubectl apply ran successfully ^^^^^^\033[0m"
  fi

  # Print out the ingress objects for logs and the ping stack
  log
  log '--- Ingress URLs ---' | tee -a "${LOG_FILE}"
  kubectl get ingress -A --context "${K8S_CONTEXT}" | tee -a "${LOG_FILE}"

  # Print out the pingdirectory hostname
  log
  log '--- LDAP hostname ---'
  kubectl get svc pingdirectory-admin -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.external-dns\.alpha\.kubernetes\.io/hostname}' \
    --context "${K8S_CONTEXT}" | tee -a "${LOG_FILE}"

  # Print out the  pods for the ping stack
  log
  log
  log '--- Pod status ---'
  kubectl get pods -n "${NAMESPACE}" --context "${K8S_CONTEXT}" | tee -a "${LOG_FILE}"

  log
  if test "${skipTest}" = 'true'; then
    log "Skipping integration and unit tests"
  else

    TEST_ENV_VARS_FILE=$(mktemp)
    cat > "${TEST_ENV_VARS_FILE}" <<EOF
export CLUSTER_NAME=${TENANT_NAME}
export IS_MULTI_CLUSTER=${IS_MULTI_CLUSTER}

export TENANT_NAME='dev-env'

export REGION=${REGION}
export REGION_NICK_NAME=${REGION_NICK_NAME}
export PRIMARY_REGION=${PRIMARY_REGION}

export TENANT_DOMAIN=${TENANT_DOMAIN}
export PRIMARY_TENANT_DOMAIN=${PRIMARY_TENANT_DOMAIN}
export GLOBAL_TENANT_DOMAIN=${GLOBAL_TENANT_DOMAIN}

export ENVIRONMENT=${ENVIRONMENT}
export BELUGA_ENV_NAME="${BELUGA_ENV_NAME}"
export ENV=${BELUGA_ENV_NAME}

export NAMESPACE=${NAMESPACE}

export NEW_RELIC_ENVIRONMENT_NAME=${NEW_RELIC_ENVIRONMENT_NAME}

export CONFIG_PARENT_DIR=aws
export CONFIG_REPO_BRANCH=${CONFIG_REPO_BRANCH}

export ARTIFACT_REPO_URL=${ARTIFACT_REPO_URL}
export PING_ARTIFACT_REPO_URL=${PING_ARTIFACT_REPO_URL}
export LOG_ARCHIVE_URL=${LOG_ARCHIVE_URL}
export BACKUP_URL=${BACKUP_URL}

export MYSQL_SERVICE_HOST=${MYSQL_SERVICE_HOST}
export MYSQL_USER=${MYSQL_USER}
export MYSQL_PASSWORD=${MYSQL_PASSWORD}
export MYSQL_DATABASE=${MYSQL_DATABASE}

export PLATFORM_EVENT_QUEUE_NAME=${PLATFORM_EVENT_QUEUE_NAME}
export ORCH_API_SSM_PATH_PREFIX=${ORCH_API_SSM_PATH_PREFIX}
export SERVICE_SSM_PATH_PREFIX=${SERVICE_SSM_PATH_PREFIX}

export PING_IDENTITY_DEVOPS_USER=${PING_IDENTITY_DEVOPS_USER}
export PING_IDENTITY_DEVOPS_KEY=${PING_IDENTITY_DEVOPS_KEY}

export LEGACY_LOGGING=${LEGACY_LOGGING}

export PROJECT_DIR=${PWD}
export AWS_PROFILE=${AWS_PROFILE:-csg}

# Other dev-env specific variables
export SKIP_CONFIGURE_KUBE=true
export SKIP_CONFIGURE_AWS=true

export DEV_TEST_ENV=true
EOF

    log "Waiting for pods in ${NAMESPACE} to be ready..."
    for DEPLOYMENT in $(kubectl get statefulset,deployment -n "${NAMESPACE}" -o name --context "${K8S_CONTEXT}"); do
      NUM_REPLICAS=$(kubectl get "${DEPLOYMENT}" -o jsonpath='{.spec.replicas}' \
        -n "${NAMESPACE}" --context "${K8S_CONTEXT}")
      TIMEOUT=$((NUM_REPLICAS * 900))
      time kubectl rollout status --timeout "${TIMEOUT}"s "${DEPLOYMENT}" \
        -n "${NAMESPACE}" -w --context "${K8S_CONTEXT}" | tee -a "${LOG_FILE}"
    done

    log "Running integration tests"
    for integration_test_dir in $(find 'ci-scripts/test/integration' -type d -mindepth 1 -maxdepth 1 -exec basename '{}' \;); do
      log
      log "==============================================================================================="
      log "      Executing integration tests in directory: ${integration_test_dir}            "
      log "==============================================================================================="

      ci-scripts/test/integration/run-integration-tests.sh "${integration_test_dir}" "${TEST_ENV_VARS_FILE}"
      test_result=$?

      integration_test_failures=$((${integration_test_failures} + ${test_result}))

      # Exit immediately if there's a test failure
      if test ${integration_test_failures} -gt 0; then
        break
      fi
    done
    log

    if test ${integration_test_failures} -ne 0; then
      RED='\033[0;31m'
      NO_COLOR='\033[0m'
      # Use printf to print in color
      printf '+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n'
      printf "Integration Test Failures: ${RED} ${integration_test_failures} Integration test(s) failed.  See details above.  Exiting...${NO_COLOR}\n"
      printf '+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n'
      exit 1
    fi
  fi
else
  less "${DEPLOY_FILE}"
fi

popd  > /dev/null 2>&1
