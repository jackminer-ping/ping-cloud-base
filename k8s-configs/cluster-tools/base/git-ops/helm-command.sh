#!/bin/bash

echo "Got args: $@" >> /tmp/jack-helm.txt

if [[ $@ = pull* && $@ = *oci://* ]]; then
  if [[ $@ = *--repo* ]]; then
    # If the command is `helm pull (..)` skips --repo flag and chartName
    # from command line args to make helm pull run

    # For explanation:
    # https://github.com/kubernetes-sigs/kustomize/issues/4381

    #echo "args 1: $@" >> /tmp/jack-args.txt
    # remove everything up until --repo
    arr=(${@//--repo/});  # Skipping --repo
    #echo "args 2: ${arr}" >> /tmp/jack-args.txt
    # get elements 0 through 5, and end to 6, removing all else
    args="${arr[@]:0:5} ${arr[@]:6}";  # Skipping chartName
    #echo "args 3: ${args}" >> /tmp/jack-args.txt
  else
    # Remove from the end of the string up until the first /
    # This removes the duplicate repo name
    args="$@"
    echo "args 1: ${args}" >> /tmp/jack-new-args.txt
    args[4]="${args[4]%\/*}"
    echo "args 2: ${args}" >> /tmp/jack-new-args.txt
  fi
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
