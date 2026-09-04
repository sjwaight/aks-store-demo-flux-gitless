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
        count: 2
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
