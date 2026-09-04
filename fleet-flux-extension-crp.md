# Setup Fleet to use CRP / RP with AKS and Flux

Install the Flux extension to allow Microsoft to manage setup and update of Flux, use Fleet Manager resource placement to rollout your apps and have Flux reconcile on cluster.

Pre-requisites:

1. Fleet Manager with a hub cluster.
1. Flux CRDs deployed to the hub cluster - easiest way is:

    ```bash
    kubectl --context hub apply -k github.com/fluxcd/flux2/manifests/crds?ref=main
    ```

1. One or more member cluster added to the fleet.

## Step 1: Deploy AKS cluster with Flux extension

Run the bicep to deploy AKS cluster with Flux extension installed, minus any deployment configs ([source file](./01-new-cluster.bicep)).

Once deployed, add the cluster to an existing Fleet Manager with a hub cluster.

```bicep
@description('AKS cluster name')
param aksName string = 'aks-member-flux-01'

@description('Location')
param location string = resourceGroup().location

resource aks 'Microsoft.ContainerService/managedClusters@2025-02-01' = {
  name: aksName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: aksName

    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: 1
        vmSize: 'Standard_D2s_v5'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]

    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
    }
  }
}

resource fluxExtension 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = {
  name: 'flux'
  scope: aks
  properties: {
    extensionType: 'microsoft.flux'
    autoUpgradeMinorVersion: true

    configurationSettings: {
      'multiTenancy.enforce': 'true'
    }
  }
}
```

## Step 2: deploy the app namespace to clusters

Use Fleet Manager resource placement to roll out the namespace

Perform the following the Fleet Manager hub cluster.

```bash
kubectl --context hub create ns aks-store-demo
```

Roll the namespace out by using the following `ClusterResourcePlacement`. We'll apply on all clusters in the fleet.

```yaml
apiVersion: placement.kubernetes-fleet.io/v1
kind: ClusterResourcePlacement
metadata:
  name: crp-rollout-demo-namespace
spec:
  resourceSelectors:
    - group: ""
      version: v1
      kind: Namespace
      name: aks-store-demo
      selectionScope: NamespaceOnly
  policy:
    placementType: PickAll
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 25%
    applyStrategy:
      type: ServerSideApply
      comparisonOption: PartialComparison
      whenToApply: IfNotDrifted
      whenToTakeOver: IfNoDiff
```

## Step 3: Authorize Flux on member clusters

Because we don't utilize the FluxConfig ARM resource we need to manually configure the right service account and cluster role binding to enable Flux's controllers to work as expected.

Save this YAML and apply to the Fleet Manager Hub Cluster ([source file](./custombinding.yaml)). You'd need to update for every namespace because we enabled Flux's multi-tenancy model by default.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flux-applier
  namespace: aks-store-demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: flux-applier-fleet-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: flux-applier
  namespace: aks-store-demo
```

Roll out the `ClusterRoleBinding` to all clusters in the fleet.

```yaml
apiVersion: placement.kubernetes-fleet.io/v1
kind: ClusterResourcePlacement
metadata:
  name: crp-rollout-demo-namespace
spec:
  resourceSelectors:
    - group: "rbac.authorization.k8s.io"
      version: v1
      kind: ClusterRoleBinding
      name: flux-applier-fleet-binding
  policy:
    placementType: PickAll
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 25%
    applyStrategy:
      type: ServerSideApply
      comparisonOption: PartialComparison
      whenToApply: IfNotDrifted
      whenToTakeOver: IfNoDiff
```

Roll out the `ServiceAccount` using resource placement.

```yaml
apiVersion: placement.kubernetes-fleet.io/v1
kind: ResourcePlacement
metadata:
  name: rp-rollout-sa
  namespace: aks-store-demo
spec:
  resourceSelectors:
    - group: ""
      version: v1
      kind: ServiceAccount
      name: flux-applier
  policy:
    placementType: PickAll
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 25%
    applyStrategy:
      type: ServerSideApply
      comparisonOption: PartialComparison
      whenToApply: IfNotDrifted
      whenToTakeOver: IfNoDiff
```

## Step 4: Deploy your app using Flux, OCIRepo and Kustomize

Finally on the hub cluster stage your `OCIRepository` and `Kustomization` configurations.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: aks-store-demo-source
  namespace: aks-store-demo
spec:
  interval: 10m
  url: oci://ghcr.io/sjwaight/aks-store-demo-flux-gitless
  ref:
    tag: 2.2.0
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: aks-store-demo
  namespace: aks-store-demo
spec:
  interval: 10m
  path: ./
  prune: true
  sourceRef:
    kind: OCIRepository
    name: aks-store-demo-source
  targetNamespace: aks-store-demo
```

Now, finally, roll the application out to your fleet, allowing Flux to reconcile on each cluster.

```yaml
apiVersion: placement.kubernetes-fleet.io/v1
kind: ResourcePlacement
metadata:
  name: rp-aks-store-oci
  namespace: aks-store-demo
spec:
  resourceSelectors:
    - group: source.toolkit.fluxcd.io
      version: v1
      kind: OCIRepository
      name: aks-store-demo-source

    - group: kustomize.toolkit.fluxcd.io
      version: v1
      kind: Kustomization
      name: aks-store-demo

  policy:
    placementType: PickAll
  strategy:
    type: RollingUpdate
```

### Use Helm instead

Alternatively, you can also use `HelmRepository` and `HelmRelease` as well.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: aks-store-demo-repo
  namespace: aks-store-demo
spec:
  interval: 10m
  url: https://Azure-Samples.github.io/aks-store-demo
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: aks-store-demo-rel
  namespace: aks-store-demo
spec:
  interval: 30m
  chart:
    spec:
      chart: aks-store-demo-chart
      version: 1.6.0
      sourceRef:
        kind: HelmRepository
        name: aks-store-demo-repo
```

Now, finally, roll the application out to your fleet, allowing Flux to reconcile on each cluster.

```yaml
apiVersion: placement.kubernetes-fleet.io/v1
kind: ResourcePlacement
metadata:
  name: rp-aks-store-helm
  namespace: aks-store-demo
spec:
  resourceSelectors:
    - group: source.toolkit.fluxcd.io
      version: v1
      kind: HelmRepository
      name: aks-store-demo-repo

    - group: helm.toolkit.fluxcd.io
      version: v2
      kind: HelmRelease
      name: aks-store-demo-rel

  policy:
    placementType: PickAll
  strategy:
    type: RollingUpdate
```

## Step 5: Check services and test app

On each member cluster you will find the application deployed, and can then access the `store-front` and `store-admin` web sites to test out.
