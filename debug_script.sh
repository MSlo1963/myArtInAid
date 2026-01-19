#!/bin/bash

# Simple debug script to add bind_values to YAML blocks
# This version has extensive debugging to see what's happening
# Usage: ./debug_script.sh input.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml_file>"
    exit 1
fi

# Create backup
BACKUP_FILE="$YAML_FILE.backup.$(date +%Y%m%d_%H%M%S)"
cp "$YAML_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"

# Create output file
OUTPUT_FILE="$YAML_FILE.new"
> "$OUTPUT_FILE"

echo "=== DEBUG: Starting to process $YAML_FILE ==="

# Simple approach: read each line and track state
current_block=""
current_id=""
in_multiline_sql=false
sql_content=""
block_lines=()

process_current_block() {
    if [ -z "$current_id" ]; then
        return
    fi

    echo "=== DEBUG: Processing block '$current_id' ==="
    echo "SQL content: '$sql_content'"

    # Count ? parameters
    param_count=$(echo "$sql_content" | tr -cd '?' | wc -c)
    echo "Parameter count: $param_count"

    # Output the block header
    echo "-- id: $current_id" >> "$OUTPUT_FILE"

    # Output all the lines we collected
    for line in "${block_lines[@]}"; do
        echo "$line" >> "$OUTPUT_FILE"
    done

    # Add bind_values if needed
    if [ "$param_count" -gt 0 ]; then
        # Check if we already have bind_values
        has_bind_values=false
        for line in "${block_lines[@]}"; do
            if [[ "$line" =~ bind_values: ]]; then
                has_bind_values=true
                break
            fi
        done

        if [ "$has_bind_values" = false ]; then
            echo "Adding bind_values section..."

            # Simple approach: just add generic parameter names
            # Check if we have a meta section
            has_meta=false
            for line in "${block_lines[@]}"; do
                if [[ "$line" =~ ^[[:space:]]*meta: ]]; then
                    has_meta=true
                    break
                fi
            done

            if [ "$has_meta" = false ]; then
                echo "  meta:" >> "$OUTPUT_FILE"
            fi

            echo "    bind_values:" >> "$OUTPUT_FILE"
            for ((i=1; i<=param_count; i++)); do
                echo "      - param$i" >> "$OUTPUT_FILE"
            done
        fi
    fi

    echo "" >> "$OUTPUT_FILE"
    echo "=== DEBUG: Finished processing block '$current_id' ==="
}

# Read file line by line
line_number=0
while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    echo "DEBUG Line $line_number: '$line'"

    # Check for new block
    if [[ "$line" =~ ^--[[:space:]]*id:[[:space:]]*(.+)$ ]]; then
        echo "DEBUG: Found new block ID: '${BASH_REMATCH[1]}'"

        # Process previous block
        if [ -n "$current_id" ]; then
            process_current_block
        fi

        # Start new block
        current_id="${BASH_REMATCH[1]}"
        block_lines=()
        sql_content=""
        in_multiline_sql=false

    elif [ -n "$current_id" ]; then
        # We're in a block, collect the line
        block_lines+=("$line")

        # Handle SQL extraction
        if [[ "$line" =~ ^[[:space:]]*sql:[[:space:]]*\|[[:space:]]*$ ]]; then
            echo "DEBUG: Start of multiline SQL"
            in_multiline_sql=true
        elif [[ "$line" =~ ^[[:space:]]*sql:[[:space:]]+(.+)$ ]] && [[ ! "$line" =~ \| ]]; then
            echo "DEBUG: Single line SQL: '${BASH_REMATCH[1]}'"
            sql_content="${BASH_REMATCH[1]}"
            in_multiline_sql=false
        elif [ "$in_multiline_sql" = true ]; then
            # Check if this is SQL content or end of SQL
            if [[ "$line" =~ ^[[:space:]]+(.+)$ ]] && [[ ! "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]] ]]; then
                echo "DEBUG: SQL content line: '${BASH_REMATCH[1]}'"
                sql_line="${BASH_REMATCH[1]}"
                sql_content="$sql_content $sql_line"
            else
                echo "DEBUG: End of multiline SQL"
                in_multiline_sql=false
            fi
        fi
    else
        echo "DEBUG: Line outside of any block, ignoring"
    fi

done < "$YAML_FILE"

# Process the last block
if [ -n "$current_id" ]; then
    echo "DEBUG: Processing final block"
    process_current_block
fi

# Replace original file
echo "=== DEBUG: Moving $OUTPUT_FILE to $YAML_FILE ==="
mv "$OUTPUT_FILE" "$YAML_FILE"

echo "Processing completed!"
echo "Check the debug output above to see what happened"
