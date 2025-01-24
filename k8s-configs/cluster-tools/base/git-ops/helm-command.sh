#!/bin/bash

# This script was initially based on https://github.com/kubernetes-sigs/kustomize/issues/4381#issuecomment-1421360675
# in order to handle older versions of Kustomize not correctly passing arguments to Helm.
# Now, with newer versions of Kustomize, we need to handle older helm charts where we duplicated the chart name in the
# repo - this script handles that as well.
# This way, if customer-hub is upgraded first, this helm shim can handle older charts contained in dev/test/stage/prod

echo "Initial args: $args" >> /tmp/helm-debug

if [[ $@ = pull* && $@ = *oci://* ]]; then
  if [[ $@ = *--repo* ]]; then
    # If the command is `helm pull (..)` skips --repo flag and chartName
    # from command line args to make helm pull run

    # For explanation:
    # https://github.com/kubernetes-sigs/kustomize/issues/4381

    arr=(${@//--repo/});  # Skipping --repo
    args="${arr[@]:0:5} ${arr[@]:6}";  # Skipping chartName
    echo "Args after removing --repo: $args" >> /tmp/helm-debug
else
    args="$@"
fi

helm_install=$(which helm)

if [ $? != 0 ]; then
  echo "Helm is not installed on this system, exiting."
  exit 1
fi

cmd="${helm_install} --registry-config /helm-working-dir/registry/config.json $args"
echo "Running '$cmd' " >> /tmp/helm-debug
eval $cmd
