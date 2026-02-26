#!/bin/bash
set -e

# Define the list of node folders
NODES=("nas-1" "nas-2" "server-1" "mac-1")

# Get the absolute path of the starting directory
BASE_DIR=$(pwd)

for NODE in "${NODES[@]}"; do
    NODE_PATH="$BASE_DIR/nodes/$NODE"
    
    echo "------------------------------------------"
    echo "🛠️  Processing node: $NODE"
    echo "------------------------------------------"

    # Enter the directory (if it exists)
    cd "$NODE_PATH"

    # Source the env and run the installer
    # Using 'set -a' exports all variables in the .env automatically
    if [ -f .env ]; then
        set -a
        source .env
        set +a
    else
        echo "⚠️  Warning: .env not found in $NODE_PATH"
    fi

    # Execute the install script
    if [ -f ./install.sh ]; then
        chmod +x ./install.sh
        ./install.sh
    else
        echo "❌ Error: install.sh not found in $NODE"
        exit 1
    fi

    # Go back to base for the next loop iteration
    cd "$BASE_DIR"
done

echo "✅ All nodes processed successfully!"
