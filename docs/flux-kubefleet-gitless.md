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

## Bootstrap on the KubeFleet hub cluster

Prerequisites:

- Flux source-controller and kustomize-controller are installed on the hub cluster.
- KubeFleet is installed and member clusters are joined.
- Target member clusters are labelled:

```bash
kubectl label membercluster <member-cluster-name> aks-store-demo/enabled=true
```

Apply the tenant bootstrap:

```bash
kubectl apply -k clusters/hub/tenants/aks-store
```

Flux first reconciles `apps/aks-store/overlays/fleet` onto the hub. After that succeeds, it reconciles `fleet/placements/aks-store`, and KubeFleet rolls the `pets` namespace resources out to selected member clusters.

## Validate

```bash
flux get sources oci -n tenant-aks-store
flux get kustomizations -n tenant-aks-store
kubectl get clusterresourceplacement aks-store-demo
kubectl get clusterresourceplacement aks-store-demo -o yaml
```

On each selected member cluster:

```bash
kubectl get pods,svc -n pets
```
