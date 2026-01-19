#!/bin/bash

# Simple script to add correct bind_values to YAML SQL blocks
# Extracts column names from SQL ? parameters in the order they appear
# Usage: ./simple_fix.sh input.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml_file>"
    exit 1
fi

# Create backup
BACKUP_FILE="$YAML_FILE.backup.$(date +%Y%m%d_%H%M%S)"
cp "$YAML_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"

# Create temp file
TEMP_FILE=$(mktemp)

# Process each line
current_block=""
current_id=""
sql_content=""
in_multiline_sql=false
has_meta=false
has_bind_values=false

while IFS= read -r line || [ -n "$line" ]; do
    # Check for new block
    if [[ "$line" =~ ^--[[:space:]]+id:[[:space:]]+(.+)$ ]]; then
        # Process previous block if exists
        if [ -n "$current_block" ]; then
            process_block
        fi

        # Start new block
        current_id="${BASH_REMATCH[1]}"
        current_block="$line"$'\n'
        sql_content=""
        in_multiline_sql=false
        has_meta=false
        has_bind_values=false
        continue
    fi

    # Add line to current block
    if [ -n "$current_block" ]; then
        current_block="$current_block$line"$'\n'

        # Check for SQL with pipe (multiline)
        if [[ "$line" =~ ^[[:space:]]*sql:[[:space:]]*\| ]]; then
            in_multiline_sql=true
        # Check for single line SQL
        elif [[ "$line" =~ ^[[:space:]]*sql:[[:space:]]*(.+)$ ]] && [[ ! "$line" =~ \| ]]; then
            sql_content="${BASH_REMATCH[1]}"
            in_multiline_sql=false
        # Collect multiline SQL content
        elif $in_multiline_sql && [[ "$line" =~ ^[[:space:]]+(.+)$ ]] && [[ ! "$line" =~ ^[[:space:]]*[a-zA-Z_] ]]; then
            sql_line=$(echo "$line" | sed 's/^[[:space:]]*//')
            if [ -n "$sql_line" ]; then
                sql_content="$sql_content $sql_line"
            fi
        # Check for meta section
        elif [[ "$line" =~ ^[[:space:]]*meta: ]]; then
            has_meta=true
            in_multiline_sql=false
        # Check for existing bind_values
        elif [[ "$line" =~ ^[[:space:]]*bind_values: ]]; then
            has_bind_values=true
        # Other YAML keys end multiline SQL
        elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_] ]]; then
            in_multiline_sql=false
        fi
    fi
done < "$YAML_FILE"

# Process last block
if [ -n "$current_block" ]; then
    process_block
fi

# Function to process a block
process_block() {
    # Count ? parameters
    param_count=$(echo "$sql_content" | tr -cd '?' | wc -c)

    echo "Processing $current_id: $param_count parameters"

    if [ "$param_count" -gt 0 ] && [ "$has_bind_values" = false ]; then
        # Extract column names from SQL
        bind_values=()

        # Handle INSERT statements
        if echo "$sql_content" | grep -qi "INSERT"; then
            # Extract columns from INSERT INTO table (col1, col2, col3) pattern
            insert_cols=$(echo "$sql_content" | sed -n 's/.*INSERT[[:space:]]\+INTO[[:space:]]\+[^(]*(\([^)]*\)).*/\1/p' | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            if [ -n "$insert_cols" ]; then
                while IFS= read -r col; do
                    if [ -n "$col" ]; then
                        bind_values+=("$col")
                    fi
                done <<< "$insert_cols"
            fi
        else
            # For other SQL types, find column = ? patterns
            while IFS= read -r match; do
                if [ -n "$match" ]; then
                    # Remove table prefix (e.g., c.status -> status)
                    column=$(echo "$match" | sed 's/.*\.//')
                    bind_values+=("$column")
                fi
            done < <(echo "$sql_content" | grep -oE '[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*[=<>!]+[[:space:]]*\?' | sed 's/[[:space:]]*[=<>!][^?]*\?//')
        fi

        # If we couldn't extract enough columns, use placeholders
        if [ "${#bind_values[@]}" -ne "$param_count" ]; then
            echo "  Using placeholder names"
            bind_values=()
            for ((i=1; i<=param_count; i++)); do
                bind_values+=("param$i")
            done
        fi

        # Add bind_values to the block
        if [ "$has_meta" = true ]; then
            # Insert bind_values after meta: line
            echo "$current_block" | sed '/^[[:space:]]*meta:/a\    bind_values:' > "$TEMP_FILE.block"
            for val in "${bind_values[@]}"; do
                sed -i "/^[[:space:]]*bind_values:/a\\      - $val" "$TEMP_FILE.block"
            done
            cat "$TEMP_FILE.block" >> "$TEMP_FILE"
        else
            # Add new meta section
            echo -n "$current_block" >> "$TEMP_FILE"
            echo "  meta:" >> "$TEMP_FILE"
            echo "    bind_values:" >> "$TEMP_FILE"
            for val in "${bind_values[@]}"; do
                echo "      - $val" >> "$TEMP_FILE"
            done
            echo "" >> "$TEMP_FILE"
        fi
    else
        if [ "$param_count" -gt 0 ]; then
            echo "  Skipping: bind_values already exists"
        else
            echo "  No parameters found"
        fi
        echo -n "$current_block" >> "$TEMP_FILE"
    fi
}

# Replace original file
mv "$TEMP_FILE" "$YAML_FILE"

# Clean up
rm -f "$TEMP_FILE.block" 2>/dev/null

echo "Processing completed!"
echo "Original backed up as: $BACKUP_FILE"
