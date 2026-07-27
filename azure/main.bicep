// Azure Trusted Launch VM (Gen2 + vTPM + Secure Boot) for the SSH device-identity
// demo. Deployed at resource-group scope:
//   az group create -n <rg> -l <loc>
//   az deployment group create -g <rg> -f azure/main.bicep -p sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
//
// Validate locally with:  az bicep build -f main.bicep

@description('OpenSSH public key for the admin user (ssh-ed25519 / ssh-rsa ...). Provisioning key only — the operator logs in via the SSH cert.')
param sshPublicKey string

@description('Inbound source for SSH. Defaults to "*" (internet) — the hardware SSH cert is the access control. Narrow to a /32 for network-layer scoping on top.')
param sshIngressCidr string = '*'

param vmName string = 'vtpm-ssh'
// Standard_D2s_v5 is a widely-available Trusted Launch size. Standard_B2als_v2
// (burstable) is a cheaper vTPM-capable alternative if your region offers it.
param vmSize string = 'Standard_D2s_v5'
param adminUsername string = 'azureuser'

@description('Use a Spot VM (eviction policy Deallocate) to save cost.')
param useSpot bool = true

param location string = resourceGroup().location

var prefix = 'vtpm-ssh'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${prefix}-nsg'
  location: location
  properties: {
    // Only SSH (22) is exposed; the hardware SSH cert (sshd TrustedUserCAKeys) is
    // the gate. No cert ⇒ refused at the SSH auth layer even though the port is
    // reachable. Set sourceAddressPrefix to a /32 for network-layer scoping too.
    securityRules: [
      {
        name: 'SSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: sshIngressCidr
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${prefix}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.42.0.0/16' ] }
    subnets: [
      {
        name: '${prefix}-subnet'
        properties: { addressPrefix: '10.42.1.0/24' }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${prefix}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${prefix}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'internal'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
        }
      }
    ]
    networkSecurityGroup: { id: nsg.id }
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    // Trusted Launch: Gen2 image + vTPM + Secure Boot.
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        vTpmEnabled: true
        secureBootEnabled: true
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      // Gen2 Ubuntu 24.04 (Noble) — the unsuffixed "server" SKU is the Gen2 image
      // (required for Trusted Launch). Verify per region with:
      //   az vm image list-skus -l <region> -p Canonical -f ubuntu-24_04-lts -o table
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
    priority: useSpot ? 'Spot' : 'Regular'
    evictionPolicy: useSpot ? 'Deallocate' : null
    billingProfile: useSpot ? { maxPrice: -1 } : null
  }
}

output instance_id string = vm.id
output vm_name string = vm.name
output resource_group string = resourceGroup().name
output public_ip string = pip.properties.ipAddress
output ssh_user string = adminUsername
