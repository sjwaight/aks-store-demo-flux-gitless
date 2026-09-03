# Flux and KubeFleet deployment

This layout turns AKS Store Demo into a Flux-deployable, gitless GitOps package for a KubeFleet hub.

## Architecture

- `apps/aks-store/overlays/fleet` builds the AKS Store Demo app into the `pets` namespace from the upstream Kustomize base.
- `clusters/hub/tenants/aks-store` is the hub-cluster bootstrap entry point for Flux. Its `Kustomization`/`OCIRepository`/RBAC objects live in the `flux-system` namespace, not `pets`, so KubeFleet never sees them as part of the app namespace (see [Where Flux runs](#where-flux-runs) below).
- Flux uses an `OCIRepository`, not a `GitRepository`, so the deployable source is a signed/versioned OCI artifact rather than a live Git checkout.
- `fleet/placements/aks-store` contains the KubeFleet `ClusterResourcePlacement` that propagates the `pets` namespace and all resources in it to member clusters labelled `aks-store-demo/enabled=true`. Because Flux's own control objects no longer live in `pets`, this CRP only ever ships plain application manifests, so member clusters do not need the Flux CRDs installed.

## Where Flux runs

There are two valid, **mutually exclusive** ways to get the rendered app and the KubeFleet placement onto member clusters. Do not combine them: running Flux's own reconciler on a member cluster against resources that KubeFleet also owns causes both controllers to fight over the same objects.

- **Option A (default in this repo): Flux hub-only.** Flux runs only on the hub; the `pets` namespace only ever contains rendered application manifests, so member clusters need no Flux CRDs or controllers. Use this unless you have a specific reason not to.
- **Option B (alternative): Flux on hub and members.** Each member cluster runs its own Flux reconciler against a `Kustomization`/`OCIRepository` pair that KubeFleet ships to it, so members can reconcile the app independently of hub connectivity. This requires undoing part of Option A.

Both options share the same first two steps (publish the OCI artifact, install Flux + KubeFleet prerequisites on the hub); follow the step-by-step guide for the option you're using from there.

## Step 1: Package the repository as a Flux OCI artifact

Publish the repository contents to an OCI registry that Flux can read, for example Azure Container Registry:

```bash
az acr login --name <acr-name>

flux push artifact \
  oci://<acr-name>.azurecr.io/platform/aks-store-demo-flux:0.1.0 \
  --path=. \
  --source="$(git config --get remote.origin.url)" \
  --revision="$(git rev-parse --short HEAD)"
```

Use Flux source-controller Azure authentication, such as AKS kubelet managed identity or Azure Workload Identity, to grant pull access to the registry. Both tenants' `source.yaml` files (`clusters/hub/tenants/aks-store/source.yaml` and, for Option B, `clusters/hub/tenants/flux-system-member/source.yaml`) are updated to point at this artifact in the steps below.

## Step 2: Install Flux and KubeFleet prerequisites on the hub

Prerequisites:

- `kubectl` is configured with contexts for the KubeFleet hub and every member cluster.
- The Flux CLI is installed on the administration workstation.
- KubeFleet hub agent is [deployed via helm](https://github.com/kubefleet-dev/kubefleet/blob/main/charts/hub-agent/README.md) using `--set enableWorkload=true` to allow Flux components to run.

Install the Flux source and Kustomize controllers on the hub. If Flux is already managed on the hub, skip `flux install` and use `flux check` to verify it instead.

```bash
kubectl config use-context <hub-context>
flux check --pre
flux install --components=source-controller,kustomize-controller
flux check

kubectl rollout status deployment/source-controller -n flux-system
kubectl rollout status deployment/kustomize-controller -n flux-system
```

Only these two controllers are required by this layout: source-controller pulls the OCI artifact and kustomize-controller reconciles the application and KubeFleet placement manifests.

Confirm the KubeFleet APIs are available and members are joined:

```bash
kubectl get crd clusterresourceplacements.placement.kubernetes-fleet.io
kubectl get memberclusters
```

## Option A: Flux hub-only (step-by-step)

Prerequisites: complete [Step 1](#step-1-package-the-repository-as-a-flux-oci-artifact) and [Step 2](#step-2-install-flux-and-kubefleet-prerequisites-on-the-hub).

1. **Confirm the tenant's control objects target `flux-system`, not `pets`.** In this repo `clusters/hub/tenants/aks-store/source.yaml`, `app-sync.yaml`, `fleet-sync.yaml`, and the `ServiceAccount` in `rbac.yaml` already use `namespace: flux-system`. This keeps the `Kustomization`/`OCIRepository` objects out of the `pets` namespace so the `aks-store-demo` CRP never ships them to member clusters.
2. **Point the `OCIRepository` at your published artifact.** Edit [clusters/hub/tenants/aks-store/source.yaml](../clusters/hub/tenants/aks-store/source.yaml):

   ```yaml
   spec:
     provider: azure
     url: oci://<acr-name>.azurecr.io/platform/aks-store-demo-flux
     ref:
       tag: 0.1.0
   ```

   For a public GHCR artifact built by this repo's GitHub Actions workflow, use the generic provider instead (pushes to `main` publish `latest`; Git tags publish matching OCI tags):

   ```yaml
   spec:
     provider: generic
     url: oci://ghcr.io/<owner>/<repository>
     ref:
       tag: latest
   ```

3. **For a private GHCR package**, create a pull secret in the `flux-system` namespace and reference it from the `OCIRepository`. Do not commit the credential.

   ```bash
   kubectl create secret docker-registry ghcr-auth \
     --namespace flux-system \
     --docker-server=ghcr.io \
     --docker-username=<github-user> \
     --docker-password=<github-token>
   ```

   ```yaml
   spec:
     provider: generic
     secretRef:
       name: ghcr-auth
     url: oci://ghcr.io/<owner>/<repository>
     ref:
       tag: latest
   ```

4. **Label the member clusters that should receive the app.** Do **not** install Flux on member clusters for this option.

   ```bash
   kubectl config use-context <hub-context>
   kubectl label membercluster <member-cluster-name> aks-store-demo/enabled=true
   ```

   Repeat for each target member. Verify connectivity from each member's own context; no repository manifests need to be applied directly to a member:

   ```bash
   kubectl --context <member-context> get nodes
   ```

5. **Bootstrap the tenant on the hub:**

   ```bash
   kubectl config use-context <hub-context>
   kubectl apply -k clusters/hub/tenants/aks-store
   ```

   Flux first reconciles `apps/aks-store/overlays/fleet` onto the hub (creating the `pets` namespace and app manifests). After that succeeds, it reconciles `fleet/placements/aks-store`, applying the `aks-store-demo` CRP, and KubeFleet rolls the `pets` namespace resources out to the labelled member clusters.

6. **Validate:**

   ```bash
   kubectl config use-context <hub-context>
   flux check
   flux get sources oci -n flux-system
   flux get kustomizations -n flux-system
   kubectl get clusterresourceplacement aks-store-demo
   kubectl get clusterresourceplacement aks-store-demo -o yaml
   ```

   On each selected member cluster (only plain app resources, no Flux objects, should be present):

   ```bash
   kubectl --context <member-context> get pods,svc -n pets
   kubectl --context <member-context> api-resources | grep fluxcd  # expect no output
   ```

## Option B: Flux on hub and members (step-by-step)

Prerequisites: complete [Step 1](#step-1-package-the-repository-as-a-flux-oci-artifact) and [Step 2](#step-2-install-flux-and-kubefleet-prerequisites-on-the-hub).

1. **Point the `flux-system-member` `OCIRepository` at your published artifact.** Edit [clusters/hub/tenants/flux-system-member/source.yaml](../clusters/hub/tenants/flux-system-member/source.yaml) the same way as in Option A step 2 (provider/url/ref/secretRef), so the hub can pull the vendored Flux install manifest and the `fleet/placements/flux-system` CRP from the artifact.
2. **Regenerate the vendored Flux install manifest if needed** (skip if `apps/flux-system/member/flux-install.yaml` already matches the components/version you installed in Step 2):

   ```bash
   flux install --components=source-controller,kustomize-controller --export > apps/flux-system/member/flux-install.yaml
   ```

3. **Label the member clusters that should run Flux and receive the app:**

   ```bash
   kubectl config use-context <hub-context>
   kubectl label membercluster <member-cluster-name> aks-store-demo/enabled=true
   ```

   Repeat for each target member.

4. **Bootstrap the `flux-system-member` tenant on the hub** — this applies the vendored Flux manifest to the hub's own `flux-system` namespace via the `flux-system-member-install` `Kustomization`, then (once that succeeds) the `flux-system-member-placement` `Kustomization` creates the `flux-system` CRP:

   ```bash
   kubectl config use-context <hub-context>
   kubectl apply -k clusters/hub/tenants/flux-system-member
   ```

   `flux-system-member-placement` has `dependsOn: flux-system-member-install`, so if the CRP doesn't appear, check that the install `Kustomization` actually became `Ready` first — it won't create a CRP otherwise:

   ```bash
   flux get kustomizations -n flux-system
   kubectl describe kustomization flux-system-member-install -n flux-system
   ```

   A common failure here is RBAC: the vendored `flux-install.yaml` creates a `ClusterRole` (`crd-controller-flux-system`) with wildcard verbs on the Flux CRD API groups, and Kubernetes' RBAC self-escalation check blocks `flux-system-member-reconciler` from creating a `ClusterRole` granting permissions it doesn't itself already hold. `rbac.yaml` binds this service account to the built-in `cluster-admin` role for that reason — if you've narrowed it, restore that binding (or grant an equivalent superset of the embedded `ClusterRole` rules).

5. **Wait for the `flux-system` CRP to finish rolling out to every labelled member** before relying on member-side reconciliation:

   ```bash
   kubectl get clusterresourceplacement flux-system -o yaml
   ```

   Confirm `ClusterResourcePlacementApplied` is `True` for every member in `status.placementStatuses`, then confirm the controllers are actually running on a member:

   ```bash
   kubectl --context <member-context> rollout status deployment/source-controller -n flux-system
   kubectl --context <member-context> rollout status deployment/kustomize-controller -n flux-system
   ```

6. **Revert the `aks-store` tenant's control objects to `namespace: pets`** so the `aks-store-demo` CRP ships them to members (this undoes Option A's default and only makes sense once step 5 confirms members can reconcile them). Edit `namespace: flux-system` to `namespace: pets` in:
   - `clusters/hub/tenants/aks-store/source.yaml`
   - `clusters/hub/tenants/aks-store/app-sync.yaml`
   - `clusters/hub/tenants/aks-store/fleet-sync.yaml`
   - the `ServiceAccount` and `ClusterRoleBinding` subject in `clusters/hub/tenants/aks-store/rbac.yaml`
7. **Point the `aks-store` `OCIRepository` at your published artifact** using the same provider/url/ref/secretRef pattern as Option A step 2, then bootstrap the tenant:

   ```bash
   kubectl config use-context <hub-context>
   kubectl apply -k clusters/hub/tenants/aks-store
   ```

8. **Validate on the hub:**

   ```bash
   kubectl config use-context <hub-context>
   flux check
   flux get sources oci -n flux-system
   flux get kustomizations -n flux-system
   kubectl get clusterresourceplacement flux-system
   kubectl get clusterresourceplacement aks-store-demo
   ```

9. **Validate on each selected member cluster** — the app's `Kustomization`/`OCIRepository` should now be present *and* reconciling locally:

   ```bash
   kubectl --context <member-context> get pods,svc -n pets
   kubectl --context <member-context> -n pets get kustomizations,ocirepositories
   kubectl --context <member-context> flux logs -n pets
   ```
