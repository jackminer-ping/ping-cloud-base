# Testing: git-ops-command CodeCommit support

Manual verification for running the `git-ops-command` CMP sidecar on the
`argocd-init-tools` image instead of the plain ArgoCD image, so
`git-ops-command.sh` can `git clone` from private AWS CodeCommit repositories
via `git-remote-codecommit`.

## Background

`git-ops-command.sh` runs as an ArgoCD Config Management Plugin sidecar on
`argocd-repo-server`. Its `monorepo_main()` does a plain `git clone` of
`K8S_GIT_URL`, which defaults to the public GitHub repo. Setting `K8S_GIT_URL`
to a `codecommit://` URL makes git invoke the `git-remote-codecommit` helper,
which needs a working python3 + botocore to run — which the plain ArgoCD image
doesn't provide.

`argocd-cmp-server` itself is copied into the sidecar at runtime by the
`copyutil` init container (from the real ArgoCD image) via the `var-files`
volume, so the sidecar's own image doesn't need to be ArgoCD. This means the
sidecar can run on `argocd-init-tools` instead, which already has a
natively-built python3/botocore/git-remote-codecommit/envsubst — no cross-image
compatibility risk (nothing is copied from a different image).

**Prerequisites:** docker with access to `public.ecr.aws` and (for Step 0) the
Ping Identity internal registry `docker.corp.pingidentity.com`. The main
ArgoCD image is public; the init-tools base image is internal.

## Step 0 — Build the new argocd-init-tools image locally

CI hasn't published `v1.1.0` yet, so build it locally. From the
`p1as-eng-common` repo:

```sh
cd pingcloud-services/argocd-init-tools
docker build -t argocd-init-tools:v1.1.0 .
```

## Step 1 — Verify the native toolchain in the new image

Simple presence checks — nothing here is copied from another image, so if
these pass, the runtime is sound:

```sh
docker run --rm --entrypoint /bin/sh argocd-init-tools:v1.1.0 -c '
  git --version &&
  python3 --version &&
  envsubst --version | head -1 &&
  python3 -c "import botocore, git_remote_codecommit; print(\"native runtime OK, botocore \" + botocore.__version__)"
'
```

> **Note:** check `botocore`, not `boto3` — `git-remote-codecommit` depends on
> `awscli` (which brings `botocore`) but *not* on `boto3`, so boto3 is not
> installed in this image and isn't needed.

## Step 2 — Prove the ArgoCD cmp-server binary runs on this base image

This replicates what the `copyutil` init container does at pod startup
(`base/install.yaml`, the `copyutil` initContainer), then runs the sidecar with
the same mounts as the real pod — including the `plugin.yaml` config file the
real pod gets from the `git-ops-command-plugin-cm` ConfigMap. This is the one
genuinely new runtime question, since the binary was built for the ArgoCD
image's base OS and this image is Debian bullseye-based.

```sh
rm -rf /tmp/argocd-sidecar-test && mkdir -p /tmp/argocd-sidecar-test/var-files \
  /tmp/argocd-sidecar-test/cmp-config /tmp/argocd-sidecar-test/plugins \
  /tmp/argocd-sidecar-test/tmp

# Minimal plugin.yaml — same shape as the git-ops-command-plugin-cm ConfigMap
# (custom-resources.yaml) that the real pod mounts at this path
cat > /tmp/argocd-sidecar-test/cmp-config/plugin.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: git-ops-command
spec:
  generate:
    command: ["git-ops-command.sh"]
EOF

# Exactly what the copyutil init container does
docker run --rm -v /tmp/argocd-sidecar-test/var-files:/var/run/argocd \
  --entrypoint /bin/cp \
  public.ecr.aws/r2h3l6e4/pingcloud-clustertools/argo/argocd:v2.12.4 \
  -n /usr/local/bin/argocd /var/run/argocd/argocd-cmp-server

# Run the sidecar image the way kustomization.yaml does. var-files must stay
# writable: the cmp-server creates its unix socket there.
# You should see some output - kill the container when confirmed running.
docker run --rm \
  -v /tmp/argocd-sidecar-test/var-files:/var/run/argocd \
  -v /tmp/argocd-sidecar-test/plugins:/home/argocd/cmp-server/plugins \
  -v /tmp/argocd-sidecar-test/cmp-config/plugin.yaml:/home/argocd/cmp-server/config/plugin.yaml:ro \
  -v /tmp/argocd-sidecar-test/tmp:/tmp \
  --entrypoint /bin/sh argocd-init-tools:v1.1.0 -c '
  timeout 3 /var/run/argocd/argocd-cmp-server --loglevel debug; echo "cmp-server exit code: $?"
'
```

**Reading the result:** `exit code: 124` (killed by `timeout` after starting
and serving) is **success** — the binary launched. Any other exit code means
it failed to run on this base image. A fatal like
`open /home/argocd/cmp-server/config/plugin.yaml: no such file or directory`
means the binary itself ran fine (it got as far as config loading) but the
config mount above was skipped — it is not a base-image incompatibility.

## Step 3 — Credentials and a real codecommit:// clone (optional)

Uses your own AWS credentials, since the IRSA token projection only exists
inside the real pod. This proves the same code path, not the IRSA wiring
itself.

```sh
docker run --rm -it \
  -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... -e AWS_SESSION_TOKEN=... \
  -e AWS_REGION=us-west-2 \
  --entrypoint /bin/sh argocd-init-tools:v1.1.0

# then, inside the container:
python3 -c "import botocore.session as s; print(s.get_session().create_client('sts').get_caller_identity()['Arn'])"
git clone codecommit://<repo-name> /tmp/test-clone
```

## In-cluster verification (can't be done locally)

1. Deploy this branch's `k8s-configs` to a lab ArgoCD instance and confirm the
   `argocd-repo-server` pod comes up with the `git-ops-command` container on
   `argocd-init-tools:v1.1.0`, and `copyutil` still populates `var-files`.
2. Exec into the `git-ops-command` sidecar and confirm IRSA credentials resolve:

   ```sh
   kubectl -n argocd exec deploy/argocd-repo-server -c git-ops-command -- \
     python3 -c "import botocore.session as s; print(s.get_session().create_client('sts').get_caller_identity()['Arn'])"
   ```

   Should print the annotated IRSA role's ARN.
3. Set `K8S_GIT_URL` to a `codecommit://<repo>` URL for a lab customer/CDE and
   confirm `git-ops-command.sh`'s clone succeeds (check
   `/tmp/git-ops-command.log` in the sidecar, or `DEBUG=true` for stdout) and
   ArgoCD sync produces the expected uber yaml.
4. Confirm the existing public-GitHub default (`K8S_GIT_URL` unset) still works
   unchanged.

## Known issue in current working tree (unrelated to this change)

The current working tree also removes the `kustomize_5_0_3` download from
`install-custom-tools.sh` (the "WIP" commit) but `kustomization.yaml` still
mounts `kustomize_5_0_3` into both containers. A `subPath` file mount whose
source doesn't exist in the volume fails at kubelet level, so the
`argocd-repo-server` pod would hang in `ContainerCreating` with that
combination. Remove the `kustomize_5_0_3` mounts if keeping that change.
