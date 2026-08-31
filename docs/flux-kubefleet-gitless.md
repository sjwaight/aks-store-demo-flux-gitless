# Flux and KubeFleet deployment

This layout turns AKS Store Demo into a Flux-deployable, gitless GitOps package for a KubeFleet hub.

## Architecture

- `apps/aks-store/overlays/fleet` builds the AKS Store Demo app into the `pets` namespace from the upstream Kustomize base.
- `clusters/hub/tenants/aks-store` is the hub-cluster bootstrap entry point for Flux.
- Flux uses an `OCIRepository`, not a `GitRepository`, so the deployable source is a signed/versioned OCI artifact rather than a live Git checkout.
- `fleet/placements/aks-store` contains the KubeFleet `ClusterResourcePlacement` that propagates the `pets` namespace and all resources in it to member clusters labelled `aks-store-demo/enabled=true`.

## Package the repository as a Flux OCI artifact

Publish the repository contents to an OCI registry that Flux can read, for example Azure Container Registry:

```bash
az acr login --name <acr-name>

flux push artifact \
  oci://<acr-name>.azurecr.io/platform/aks-store-demo-flux:0.1.0 \
  --path=. \
  --source="$(git config --get remote.origin.url)" \
  --revision="$(git rev-parse --short HEAD)"
```

Update `clusters/hub/tenants/aks-store/source.yaml`:

```yaml
spec:
  provider: azure
  url: oci://<acr-name>.azurecr.io/platform/aks-store-demo-flux
  ref:
    tag: 0.1.0
```

Use Flux source-controller Azure authentication, such as AKS kubelet managed identity or Azure Workload Identity, to grant pull access to the registry.

## Install and configure Flux on the hub cluster

Prerequisites:

- `kubectl` is configured with contexts for the KubeFleet hub and every member cluster.
- The Flux CLI is installed on the administration workstation.

> [!NOTE]
> For the purpose of this demo, install Flux *before* KubeFleet as KubeFleet currently blocks the creation of ReplicaSet resources. We have a proposed feature to allow 
> for exclusions to these rules in future so you can install or update other resources after KubeFleet's hub agent is deployed. 

Install the Flux source and Kustomize controllers on the hub. If Flux is already managed on the hub, skip `flux install` and use `flux check` to verify it instead.

```bash
flux check --pre
flux install --components=source-controller,kustomize-controller
flux check

kubectl rollout status deployment/source-controller -n flux-system
kubectl rollout status deployment/kustomize-controller -n flux-system
```

Only these two controllers are required by this layout: source-controller pulls the OCI artifact and kustomize-controller reconciles the application and KubeFleet placement manifests.

Set the hub context and confirm that the KubeFleet APIs are available:

```bash
kubectl config use-context <hub-context>
kubectl get crd clusterresourceplacements.placement.kubernetes-fleet.io
kubectl get memberclusters
```

### Configure access to the OCI artifact

Before applying the tenant bootstrap, update [clusters/hub/tenants/aks-store/source.yaml](../clusters/hub/tenants/aks-store/source.yaml) so that `spec.url` and `spec.ref.tag` match the published artifact.

For Azure Container Registry, keep `provider: azure` and grant the AKS kubelet identity or Flux Workload Identity permission to pull from the registry:

```yaml
spec:
  provider: azure
  url: oci://<acr-name>.azurecr.io/platform/aks-store-demo-flux
  ref:
    tag: 0.1.0
```

For a public GitHub Container Registry artifact produced by this repository's GitHub Actions workflow, use the generic provider. Pushes to `main` publish `latest`, while Git tags publish matching OCI tags:

```yaml
spec:
  provider: generic
  url: oci://ghcr.io/<owner>/docker pull
  ref:
    tag: latest
```

For a private GHCR package, create the tenant namespace and a pull secret using a GitHub credential with `read:packages`, then add the shown `secretRef` to the `OCIRepository`. Do not commit the credential.

```bash
kubectl apply -f clusters/hub/tenants/aks-store/namespace.yaml
kubectl create secret docker-registry ghcr-auth \
  --namespace tenant-aks-store \
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

### Configure member clusters

Flux is installed only on the hub. Do **not** install Flux on member clusters for this layout: KubeFleet propagates the resources selected by the `ClusterResourcePlacement`, and a second reconciler on a member could compete for ownership of those resources.

Verify that each member is joined and healthy from the hub, then label the members that should receive the application:

```bash
kubectl config use-context <hub-context>
kubectl get memberclusters
kubectl label membercluster <member-cluster-name> aks-store-demo/enabled=true
```

Repeat the label command for each target member. Remove the label to stop selecting a member:

```bash
kubectl label membercluster <member-cluster-name> aks-store-demo/enabled-
```

KubeFleet member agents must already be running as part of the cluster-join process. Use each member's context to verify connectivity; no repository manifests need to be applied directly to a member:

```bash
kubectl --context <member-context> get nodes
```

## Bootstrap on the KubeFleet hub cluster

With the hub context selected, apply the tenant namespace, scoped reconciliation identity, OCI source, and Flux Kustomizations:

```bash
kubectl config use-context <hub-context>
kubectl apply -k clusters/hub/tenants/aks-store
```

Flux first reconciles `apps/aks-store/overlays/fleet` onto the hub. After that succeeds, it reconciles `fleet/placements/aks-store`, and KubeFleet rolls the `pets` namespace resources out to selected member clusters.

## Validate

```bash
kubectl config use-context <hub-context>
flux check
flux get sources oci -n tenant-aks-store
flux get kustomizations -n tenant-aks-store
kubectl get clusterresourceplacement aks-store-demo
kubectl get clusterresourceplacement aks-store-demo -o yaml
```

On each selected member cluster:

```bash
kubectl --context <member-context> get pods,svc -n pets
```
