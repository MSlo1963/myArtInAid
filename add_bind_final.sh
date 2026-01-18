#!/bin/bash

# Simple script to add bind_values to YAML blocks
# Usage: ./add_bind_final.sh input.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml_file>"
    exit 1
fi

# Create backup
BACKUP_FILE="$YAML_FILE.backup.$(date +%Y%m%d_%H%M%S)"  
cp "$YAML_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"

# Create working directory
WORK_DIR=$(mktemp -d)
RESULT_FILE="$WORK_DIR/result.yaml"

# Split file into blocks and process each
csplit -s -f "$WORK_DIR/block_" "$YAML_FILE" "/^-- id:/" "{*}" 2>/dev/null || true

# Process each block file
> "$RESULT_FILE"

for block_file in "$WORK_DIR"/block_*; do
    if [ ! -f "$block_file" ] || [ ! -s "$block_file" ]; then
        continue
    fi
    
    # Skip empty first block
    if [ "$(wc -l < "$block_file")" -eq 0 ]; then
        continue
    fi
    
    # Extract bind values from this block
    bind_values=$(grep -o -E "[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*?" "$block_file" | cut -d= -f1 | tr -d " " | sort -u | tr "
" "," | sed "s/,$//" || echo "")
    
    if [ -n "$bind_values" ]; then
        # Check if block has meta section
        if grep -q "^[[:space:]]*meta:" "$block_file"; then
            # Insert bind_values after meta line
            sed "/^[[:space:]]*meta:/a\    bind_values:" "$block_file" > "$WORK_DIR/temp_block"
            # Add each bind value as array item
            IFS="," read -ra VALUES <<< "$bind_values"
            for value in "${VALUES[@]}"; do
                sed -i "/^[[:space:]]*bind_values:/a\      - $value" "$WORK_DIR/temp_block"
            done
            cat "$WORK_DIR/temp_block" >> "$RESULT_FILE"
        else
            # Add meta section at end of block
            cat "$block_file" >> "$RESULT_FILE"
            echo "  meta:" >> "$RESULT_FILE" 
            echo "    bind_values:" >> "$RESULT_FILE"
            IFS="," read -ra VALUES <<< "$bind_values"
            for value in "${VALUES[@]}"; do
                echo "      - $value" >> "$RESULT_FILE"
            done
        fi
        echo "" >> "$RESULT_FILE"
    else
        # No bind values, copy as-is
        cat "$block_file" >> "$RESULT_FILE"
        echo "" >> "$RESULT_FILE"
    fi
done

# Replace original file
mv "$RESULT_FILE" "$YAML_FILE"

# Cleanup
rm -rf "$WORK_DIR"

echo "Bind values added successfully!"
