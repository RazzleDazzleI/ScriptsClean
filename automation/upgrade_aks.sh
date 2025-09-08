#!/bin/bash

# Define variables
RESOURCE_GROUP="1Password"
CLUSTER_NAME="SCIM"
VERSIONS=("1.30.7" "1.30.8" "1.30.9" "1.31.1" "1.31.2" "1.31.3" "1.31.4" "1.31.5")

# Function to upgrade AKS cluster version
upgrade_aks() {
    local version=$1
    echo "🚀 Starting upgrade to Kubernetes version $version..."
    
    az aks upgrade --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --kubernetes-version $version --yes
    
    if [ $? -eq 0 ]; then
        echo "✅ Successfully upgraded to $version"
    else
        echo "❌ Upgrade to $version failed. Exiting..."
        exit 1
    fi
    
    echo "⏳ Waiting for cluster to stabilize..."
    sleep 60
}

# Loop through all versions and upgrade sequentially
for VERSION in "${VERSIONS[@]}"; do
    upgrade_aks $VERSION
done

echo "🎉 AKS upgrade completed successfully!"
