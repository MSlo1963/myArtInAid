#!/bin/bash

# Ultra-simple script to add correct bind_values to YAML SQL blocks
# This script analyzes SQL statements and extracts column names that appear before ? parameters
# Usage: ./final_working_fix.sh input.yaml

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
OUTPUT_FILE="${YAML_FILE}.new"
> "$OUTPUT_FILE"

# Process file line by line
in_block=false
current_id=""
sql_lines=()
other_lines=()
has_bind_values=false

process_block() {
    if [ -z "$current_id" ]; then
        return
    fi

    echo "Processing block: $current_id"

    # Combine SQL lines into single string
    sql_content=$(printf '%s ' "${sql_lines[@]}" | sed 's/[[:space:]]\+/ /g')

    # Count ? parameters
    param_count=$(echo "$sql_content" | tr -cd '?' | wc -c)

    echo "  Found $param_count SQL parameters"

    # Extract bind values if we have parameters and no existing bind_values
    if [ "$param_count" -gt 0 ] && [ "$has_bind_values" = false ]; then
        bind_values=()

        # Method 1: Handle INSERT statements
        if echo "$sql_content" | grep -qi "INSERT.*INTO"; then
            # Extract column names from INSERT INTO table (col1, col2) VALUES (?, ?)
            cols=$(echo "$sql_content" | sed -n 's/.*INSERT[[:space:]]\+INTO[[:space:]]\+[^(]*(\([^)]*\)).*/\1/p')
            if [ -n "$cols" ]; then
                IFS=',' read -ra ADDR <<< "$cols"
                for col in "${ADDR[@]}"; do
                    clean_col=$(echo "$col" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                    bind_values+=("$clean_col")
                done
            fi
        else
            # Method 2: Find column = ? patterns (for SELECT, UPDATE, DELETE)
            # Look for patterns like: column_name = ? or table.column > ?
            while IFS= read -r match; do
                if [ -n "$match" ]; then
                    # Remove table prefix (e.g., c.status -> status)
                    column_name=$(echo "$match" | sed 's/.*\.//')
                    bind_values+=("$column_name")
                fi
            done < <(echo "$sql_content" | grep -oE '[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*[=<>!]+[[:space:]]*\?' | sed 's/[[:space:]]*[=<>!][^?]*\?//')
        fi

        # Fallback: if we couldn't extract the right number of columns, use generic names
        if [ "${#bind_values[@]}" -ne "$param_count" ]; then
            echo "  Warning: Could not extract all column names, using param1, param2, etc."
            bind_values=()
            for ((i=1; i<=param_count; i++)); do
                bind_values+=("param$i")
            done
        fi

        echo "  Extracted bind_values: ${bind_values[*]}"

        # Write the block with added bind_values
        echo "-- id: $current_id" >> "$OUTPUT_FILE"

        # Write SQL lines
        for line in "${sql_lines[@]}"; do
            echo "$line" >> "$OUTPUT_FILE"
        done

        # Process other lines and add bind_values
        has_meta=false
        for line in "${other_lines[@]}"; do
            if [[ "$line" =~ ^[[:space:]]*meta: ]]; then
                has_meta=true
                echo "$line" >> "$OUTPUT_FILE"
                echo "    bind_values:" >> "$OUTPUT_FILE"
                for val in "${bind_values[@]}"; do
                    echo "      - $val" >> "$OUTPUT_FILE"
                done
            else
                echo "$line" >> "$OUTPUT_FILE"
            fi
        done

        # If no meta section existed, add one
        if [ "$has_meta" = false ]; then
            echo "  meta:" >> "$OUTPUT_FILE"
            echo "    bind_values:" >> "$OUTPUT_FILE"
            for val in "${bind_values[@]}"; do
                echo "      - $val" >> "$OUTPUT_FILE"
            done
        fi
    else
        # No parameters or already has bind_values - just copy the block as-is
        if [ "$param_count" -eq 0 ]; then
            echo "  No parameters - copying as-is"
        else
            echo "  bind_values already exists - copying as-is"
        fi

        echo "-- id: $current_id" >> "$OUTPUT_FILE"
        for line in "${sql_lines[@]}"; do
            echo "$line" >> "$OUTPUT_FILE"
        done
        for line in "${other_lines[@]}"; do
            echo "$line" >> "$OUTPUT_FILE"
        done
    fi

    echo "" >> "$OUTPUT_FILE"
}

# Read file line by line
while IFS= read -r line || [ -n "$line" ]; do
    # Check for new block
    if [[ "$line" =~ ^--[[:space:]]*id:[[:space:]]*(.+)$ ]]; then
        # Process previous block if exists
        if [ "$in_block" = true ]; then
            process_block
        fi

        # Start new block
        in_block=true
        current_id="${BASH_REMATCH[1]}"
        sql_lines=()
        other_lines=()
        has_bind_values=false
        in_sql=false

    elif [ "$in_block" = true ]; then
        # We're in a block, categorize the line

        if [[ "$line" =~ ^[[:space:]]*sql:[[:space:]]*\| ]]; then
            # Start of multi-line SQL
            sql_lines+=("$line")
            in_sql=true

        elif [[ "$line" =~ ^[[:space:]]*sql: ]]; then
            # Single-line SQL
            sql_lines+=("$line")
            in_sql=false

        elif [ "$in_sql" = true ] && [[ "$line" =~ ^[[:space:]]+ ]] && [[ ! "$line" =~ ^[[:space:]]*[a-zA-Z_] ]]; then
            # Multi-line SQL content (indented, not a YAML key)
            sql_lines+=("$line")

        elif [[ "$line" =~ ^[[:space:]]*bind_values: ]]; then
            # Found existing bind_values
            has_bind_values=true
            other_lines+=("$line")
            in_sql=false

        else
            # Other lines (meta, db, etc.)
            other_lines+=("$line")
            in_sql=false
        fi
    fi

done < "$YAML_FILE"

# Process last block
if [ "$in_block" = true ]; then
    process_block
fi

# Replace original file with processed version
mv "$OUTPUT_FILE" "$YAML_FILE"

echo ""
echo "Processing completed successfully!"
echo "Original file backed up as: $BACKUP_FILE"
echo ""
echo "Summary of changes:"
echo "- Added bind_values sections where missing"
echo "- Extracted actual column names from SQL where possible"
echo "- Used placeholder names (param1, param2, etc.) when extraction failed"
echo "- Preserved existing bind_values sections unchanged"
