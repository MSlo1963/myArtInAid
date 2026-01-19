#!/bin/bash

# Simple script to fix bind_values in YAML files
# Extracts column names from SQL in the order they appear with ? parameters
# Usage: ./fix_bind_values.sh input.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml_file>"
    exit 1
fi

# Create backup
BACKUP_FILE="$YAML_FILE.backup.$(date +%Y%m%d_%H%M%S)"
cp "$YAML_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"

# Temp files
TEMP_DIR=$(mktemp -d)
BLOCKS_DIR="$TEMP_DIR/blocks"
mkdir -p "$BLOCKS_DIR"

# Split file into blocks
awk '
BEGIN { block_num = 0; current_file = "" }
/^-- id:/ {
    if (current_file != "") close(current_file)
    block_num++
    current_file = "'"$BLOCKS_DIR"'/block_" block_num ".yaml"
    print $0 > current_file
    next
}
current_file != "" { print $0 > current_file }
END { if (current_file != "") close(current_file) }
' "$YAML_FILE"

# Process each block
> "$YAML_FILE"

for block_file in "$BLOCKS_DIR"/block_*.yaml; do
    if [ ! -f "$block_file" ]; then
        continue
    fi

    # Extract ID and SQL
    block_id=$(grep "^-- id:" "$block_file" | awk '{print $3}')

    # Extract SQL content (handle both single line and multi-line)
    sql_content=""
    if grep -q "sql:.*|" "$block_file"; then
        # Multi-line SQL
        sql_content=$(sed -n '/sql:.*|/,/^[[:space:]]*[a-zA-Z_]/p' "$block_file" | sed '1d;$d' | sed 's/^[[:space:]]*//' | tr '\n' ' ')
    else
        # Single line SQL
        sql_content=$(grep "^[[:space:]]*sql:" "$block_file" | sed 's/^[[:space:]]*sql:[[:space:]]*//')
    fi

    if [ -n "$sql_content" ]; then
        # Count ? parameters
        param_count=$(echo "$sql_content" | tr -cd '?' | wc -c)

        echo "Processing $block_id: $param_count parameters"

        if [ "$param_count" -gt 0 ]; then
            # Extract bind values in order
            bind_values=()

            # Method 1: Look for column = ? patterns
            while IFS= read -r match; do
                if [ -n "$match" ]; then
                    # Remove table prefix if present (e.g., c.status -> status)
                    column=$(echo "$match" | sed 's/.*\.//')
                    bind_values+=("$column")
                fi
            done < <(echo "$sql_content" | grep -oE '[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*[=<>!]+[[:space:]]*\?' | sed -E 's/[[:space:]]*[=<>!]+[[:space:]]*\?//')

            # Method 2: Handle INSERT statements
            if echo "$sql_content" | grep -qi "INSERT"; then
                insert_cols=$(echo "$sql_content" | sed -n 's/.*INSERT[[:space:]]\+INTO[[:space:]]\+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(\([^)]*\)).*/\1/p' | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                if [ -n "$insert_cols" ]; then
                    bind_values=()
                    while IFS= read -r col; do
                        if [ -n "$col" ]; then
                            bind_values+=("$col")
                        fi
                    done <<< "$insert_cols"
                fi
            fi

            # If we don't have the right number, use placeholders
            if [ "${#bind_values[@]}" -ne "$param_count" ]; then
                echo "  Warning: Using placeholder names"
                bind_values=()
                for ((i=1; i<=param_count; i++)); do
                    bind_values+=("param$i")
                done
            fi

            # Add bind_values to block if not already present
            if ! grep -q "bind_values:" "$block_file"; then
                if grep -q "^[[:space:]]*meta:" "$block_file"; then
                    # Add to existing meta section
                    sed '/^[[:space:]]*meta:/a\    bind_values:' "$block_file" > "$TEMP_DIR/temp_block"
                    for val in "${bind_values[@]}"; do
                        sed -i "/^[[:space:]]*bind_values:/a\\      - $val" "$TEMP_DIR/temp_block"
                    done
                    cat "$TEMP_DIR/temp_block" >> "$YAML_FILE"
                else
                    # Add new meta section
                    cat "$block_file" >> "$YAML_FILE"
                    echo "  meta:" >> "$YAML_FILE"
                    echo "    bind_values:" >> "$YAML_FILE"
                    for val in "${bind_values[@]}"; do
                        echo "      - $val" >> "$YAML_FILE"
                    done
                fi
            else
                echo "  Skipping: bind_values already exists"
                cat "$block_file" >> "$YAML_FILE"
            fi
        else
            echo "  No parameters found"
            cat "$block_file" >> "$YAML_FILE"
        fi
    else
        echo "  No SQL found"
        cat "$block_file" >> "$YAML_FILE"
    fi

    echo "" >> "$YAML_FILE"
done

# Cleanup
rm -rf "$TEMP_DIR"

echo "Processing completed!"
echo "Original backed up as: $BACKUP_FILE"
