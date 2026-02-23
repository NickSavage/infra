#!/bin/bash

# Force script to exit on any error
set -e

# Usage check
if [ -z "$REMOTE_HOST" ]; then
    echo "❌ Error: REMOTE_HOST environment variable is not set."
    exit 1
fi
if [ -z "$REMOTE_USER" ]; then
    echo "❌ Error: REMOTE_HOST environment variable is not set."
    exit 1
fi

# --- CONFIGURATION ---
SOURCE_FOLDER=$SOURCE_FOLDER
DEST_PARENT_DIR="/config" 
FOLDER_NAME=$(basename "$SOURCE_FOLDER")
REMOTE_PATH="$DEST_PARENT_DIR/$FOLDER_NAME"

echo "🚀 Starting local lab deployment to $REMOTE_HOST..."

# 1. Ensure the parent directory exists on the remote
echo "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $DEST_PARENT_DIR"

# 2. Copy folder using scp
# -r: recursive (copies the folder and its contents)
echo "📦 Copying files via SCP..."
scp -r "$SOURCE_FOLDER" "$REMOTE_USER@$REMOTE_HOST:$DEST_PARENT_DIR"

# 3. Execute remote commands
echo "💻 Running remote commands..."

# We wrap the commands in a single SSH call. 
# "set -e" inside the quotes ensures the remote session fails if a command fails.

echo "$REMOTE_USER@$REMOTE_HOST" 
ssh "$REMOTE_USER@$REMOTE_HOST" "
    set -e
    cd '$REMOTE_PATH'
    
    if [ ! -f .env ]; then
        echo '❌ Error: .env file missing in $REMOTE_PATH'
        exit 1
    fi

    # --- YOUR COMMANDS START HERE ---
    pwd
    docker compose build
    docker compose up -d
    docker restart telegraf

    # --- YOUR COMMANDS END HERE ---

    echo '✅ Remote commands finished.'
"

echo "🎉 Done!"