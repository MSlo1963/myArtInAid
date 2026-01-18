#!/bin/bash
# Simple bind_values extractor
# Usage: ./extract_bind_values.sh test.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Error: File not found"
    exit 1
fi

# Backup
cp "$YAML_FILE" "$YAML_FILE.bak"

# Extract SQL and find bind values for myId block
echo "Analyzing SQL in myId block..."
sed -n "/-- id: myId/,/-- id:/p" "$YAML_FILE" | grep -E "[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*?" | sed "s/.*\([a-zA-Z_][a-zA-Z0-9_]*\)[[:space:]]*=[[:space:]]*?.*//"

echo "Found bind values!"
