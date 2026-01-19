#!/bin/bash

# Simple script to add bind_values to YAML blocks based on SQL parameters
# This script correctly extracts column names from SQL in the order they appear with ?
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

# Temporary file for output
TEMP_FILE=$(mktemp)

# Initialize variables
current_block=""
current_id=""
block_sql=""
processing_multiline_sql=false

# Function to extract column names from SQL in parameter order
extract_bind_values() {
    local sql="$1"

    # Remove comments and normalize whitespace
    sql=$(echo "$sql" | sed 's/--.*$//' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')

    # Handle different SQL types
    if echo "$sql" | grep -qi "INSERT.*INTO"; then
        # For INSERT: Extract column names from INSERT INTO table (col1, col2) VALUES (?, ?)
        local columns=$(echo "$sql" | sed -n 's/.*INSERT[[:space:]]\+INTO[[:space:]]\+[^(]*(\([^)]*\)).*/\1/p')
        if [ -n "$columns" ]; then
            echo "$columns" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
        fi
    else
        # For SELECT/UPDATE/DELETE: Find column = ? patterns in order
        echo "$sql" | grep -oE '[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*[=<>!]+[[:space:]]*\?' | sed 's/[[:space:]]*[=<>!][^?]*\?//' | sed 's/.*\.//'
    fi
}

# Function to process a complete block
process_block() {
    if [ -z "$current_id" ]; then
        return
    fi

    # Count ? parameters in SQL
    param_count=0
    if [ -n "$block_sql" ]; then
        param_count=$(echo "$block_sql" | tr -cd '?' | wc -c)
    fi

    echo "Processing block '$current_id': $param_count parameters"

    # Check if bind_values already exists in the block
    has_bind_values=false
    if echo "$current_block" | grep -q "bind_values:"; then
        has_bind_values=true
        echo "  -> Already has bind_values, keeping as-is"
    fi

    # Add bind_values if needed
    if [ "$param_count" -gt 0 ] && [ "$has_bind_values" = false ]; then
        # Extract column names
        bind_values=$(extract_bind_values "$block_sql")

        # Convert to array and validate count
        bind_array=()
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                bind_array+=("$line")
            fi
        done <<< "$bind_values"

        # Use fallback names if extraction failed
        if [ "${#bind_array[@]}" -ne "$param_count" ]; then
            echo "  -> Using fallback parameter names"
            bind_array=()
            for ((i=1; i<=param_count; i++)); do
                bind_array+=("param$i")
            done
        else
            echo "  -> Extracted: ${bind_array[*]}"
        fi

        # Add bind_values to the block
        if echo "$current_block" | grep -q "^[[:space:]]*meta:"; then
            # Insert after existing meta: line
            current_block=$(echo "$current_block" | sed '/^[[:space:]]*meta:/a\    bind_values:')
            for val in "${bind_array[@]}"; do
                current_block=$(echo "$current_block" | sed "/^[[:space:]]*bind_values:/a\\      - $val")
            done
        else
            # Add new meta section
            current_block="$current_block"$'\n'"  meta:"$'\n'"    bind_values:"
            for val in "${bind_array[@]}"; do
                current_block="$current_block"$'\n'"      - $val"
            done
        fi
    fi

    # Output the processed block
    echo "$current_block" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"
}

# Process the YAML file line by line
while IFS= read -r line || [ -n "$line" ]; do
    # Check for new block
    if [[ "$line" =~ ^--[[:space:]]+id:[[:space:]]+(.+)$ ]]; then
        # Process previous block
        if [ -n "$current_id" ]; then
            process_block
        fi

        # Initialize new block
        current_id="${BASH_REMATCH[1]}"
        current_block="$line"
        block_sql=""
        processing_multiline_sql=false

    elif [ -n "$current_id" ]; then
        # Add line to current block
        current_block="$current_block"$'\n'"$line"

        # Handle SQL content extraction
        if [[ "$line" =~ ^[[:space:]]*sql:[[:space:]]*\|[[:space:]]*$ ]]; then
            # Start of multiline SQL
            processing_multiline_sql=true

        elif [[ "$line" =~ ^[[:space:]]*sql:[[:space:]]*(.+)$ ]] && [[ ! "$line" =~ \| ]]; then
            # Single line SQL
            block_sql="${BASH_REMATCH[1]}"
            processing_multiline_sql=false

        elif [ "$processing_multiline_sql" = true ]; then
            # Check if this line is SQL content or end of SQL
            if [[ "$line" =~ ^[[:space:]]+(.*)$ ]] && [[ ! "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*: ]]; then
                # This is SQL content (indented, not a YAML key)
                sql_line="${BASH_REMATCH[1]}"
                block_sql="$block_sql $sql_line"
            else
                # End of multiline SQL
                processing_multiline_sql=false
            fi
        fi
    fi

done < "$YAML_FILE"

# Process final block
if [ -n "$current_id" ]; then
    process_block
fi

# Replace original file
mv "$TEMP_FILE" "$YAML_FILE"

echo ""
echo "Bind values processing completed!"
echo "Original file backed up as: $BACKUP_FILE"
echo ""
echo "The script:"
echo "- Analyzed SQL statements for ? parameters"
echo "- Extracted column names in the correct order"
echo "- Added bind_values sections where missing"
echo "- Preserved existing bind_values unchanged"
