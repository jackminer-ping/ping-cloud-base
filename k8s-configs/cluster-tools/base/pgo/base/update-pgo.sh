#!/bin/bash

if [[ ! "${0}" =~ "k8s-configs/cluster-tools/base/pgo/base" ]]; then
    echo "Script run source sanity check failed. Please only run this script in k8s-configs/cluster-tools/base/pgo/base"
fi


source ../../../../../utils.sh

# Update the PGO CRDs, other resources based on the github.com/CrunchyData/postgres-operator-examples repo.
# NOTE: only run this script in the k8s-configs/cluster-tools/base/pgo/base directory
cur_date=$(date -I seconds)
tmp_dir="/tmp/pgo/${cur_date}"
example_repo="postgres-operator-examples"
repo_dir="${tmp_dir}/${example_repo}"
repo_dir_kustomize="${repo_dir}/kustomize/install"

beluga_log "Creating tmp dir - ${tmp_dir}"
mkdir "${tmp_dir}"

git clone "https://github.com/CrunchyData/${example_repo}" "${tmp_dir}/${example_repo}"

rm -rf "${repo_dir_kustomize}/singlenamespace"

rsync -rv "${repo_dir_kustomize}/" .

