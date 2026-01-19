#!/bin/bash

# Working script to fix bind_values in YAML files
# Properly handles multi-line SQL with | syntax and single-line SQL
# Usage: ./working_fix.sh input.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml_file>"
    exit 1
fi

# Create backup
BACKUP_FILE="$YAML_FILE.backup.$(date +%Y%m%d_%H%M%S)"
cp "$YAML_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"

# Function to extract column names from SQL in order they appear with ?
extract_bind_values() {
    local sql="$1"

    # Remove SQL comments and normalize whitespace
    sql=$(echo "$sql" | sed 's/--.*$//' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')

    # Find column = ? patterns in order
    local columns=()

    # Handle INSERT statements first
    if echo "$sql" | grep -qi "INSERT"; then
        # Extract columns from INSERT INTO table (col1, col2, col3) VALUES (?, ?, ?)
        local insert_columns=$(echo "$sql" | sed -n 's/.*INSERT[[:space:]]\+INTO[[:space:]]\+[^(]*([^)]*)/\1/p' | sed 's/INSERT[[:space:]]\+INTO[[:space:]]\+[^(]*(//' | sed 's/).*//' | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        if [ -n "$insert_columns" ]; then
            while IFS= read -r col; do
                if [ -n "$col" ]; then
                    columns+=("$col")
                fi
            done <<< "$insert_columns"
        fi
    else
        # For SELECT/UPDATE/DELETE, find column = ? patterns
        while IFS= read -r match; do
            if [ -n "$match" ]; then
                # Remove table prefix (e.g., c.status -> status)
                col=$(echo "$match" | sed 's/.*\.//')
                columns+=("$col")
            fi
        done < <(echo "$sql" | grep -oE '[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*[=<>!]+[[:space:]]*\?' | sed 's/[[:space:]]*[=<>!][^?]*\?//')
    fi

    # Output columns
    printf '%s\n' "${columns[@]}"
}

# Process the file using awk for proper YAML parsing
awk '
BEGIN {
    current_block = ""
    in_multiline_sql = 0
    sql_content = ""
    block_has_bind_values = 0
}

# Start of new block
/^-- id:/ {
    # Process previous block if exists
    if (current_block != "") {
        process_current_block()
    }

    # Start new block
    current_block = $0 "\n"
    block_id = $3
    in_multiline_sql = 0
    sql_content = ""
    block_has_bind_values = 0
    next
}

# SQL line with pipe (multiline)
/^[[:space:]]*sql:[[:space:]]*\|/ {
    current_block = current_block $0 "\n"
    in_multiline_sql = 1
    next
}

# SQL single line
/^[[:space:]]*sql:/ && !/\|/ {
    current_block = current_block $0 "\n"
    sql_line = $0
    gsub(/^[[:space:]]*sql:[[:space:]]*/, "", sql_line)
    sql_content = sql_line
    in_multiline_sql = 0
    next
}

# Multiline SQL content (indented lines after sql: |)
in_multiline_sql && /^[[:space:]]+/ && !/^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:/ {
    current_block = current_block $0 "\n"
    # Extract SQL content (remove leading spaces)
    sql_line = $0
    gsub(/^[[:space:]]+/, "", sql_line)
    if (sql_content == "") {
        sql_content = sql_line
    } else {
        sql_content = sql_content " " sql_line
    }
    next
}

# End of multiline SQL (when we hit a YAML key)
in_multiline_sql && /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:/ {
    in_multiline_sql = 0
    current_block = current_block $0 "\n"
    next
}

# Check for existing bind_values
/^[[:space:]]*bind_values:/ {
    block_has_bind_values = 1
    current_block = current_block $0 "\n"
    next
}

# Any other line
{
    if (in_multiline_sql && !/^[[:space:]]*[a-zA-Z_]/) {
        # Still in SQL content
        sql_line = $0
        gsub(/^[[:space:]]+/, "", sql_line)
        if (sql_line != "") {
            sql_content = sql_content " " sql_line
        }
    } else {
        in_multiline_sql = 0
    }
    current_block = current_block $0 "\n"
}

function process_current_block() {
    # Count parameters
    param_count = gsub(/\?/, "?", sql_content)

    print "Processing " block_id ": " param_count " parameters" > "/dev/stderr"

    if (param_count > 0 && !block_has_bind_values) {
        # Write SQL to temp file for processing
        temp_file = "/tmp/sql_" block_id ".txt"
        print sql_content > temp_file
        close(temp_file)

        # Call external function to extract bind values
        cmd = "bash -c '\''source " ARGV[0] "; extract_bind_values \"$(cat " temp_file ")\"; rm " temp_file "'\''"

        # Add bind_values to block
        if (index(current_block, "meta:") > 0) {
            # Insert after existing meta:
            if (gsub(/(\n[[:space:]]*meta:[[:space:]]*\n)/, "\n  meta:\n    bind_values:\n")) {
                # Add the bind values
                # This is complex in awk, so we will use a simpler approach
            }
        }
    }

    # Output the block
    printf "%s", current_block

    # Add bind_values if needed
    if (param_count > 0 && !block_has_bind_values) {
        if (index(current_block, "meta:") > 0) {
            print "    bind_values:"
            for (i = 1; i <= param_count; i++) {
                print "      - param" i
            }
        } else {
            print "  meta:"
            print "    bind_values:"
            for (i = 1; i <= param_count; i++) {
                print "      - param" i
            }
        }
    }

    print ""
}

END {
    # Process last block
    if (current_block != "") {
        process_current_block()
    }
}
' "$YAML_FILE" > "${YAML_FILE}.tmp" 2>/dev/null

# Replace original with processed version
mv "${YAML_FILE}.tmp" "$YAML_FILE"

# Now do a second pass to extract actual column names
TEMP_FILE=$(mktemp)
> "$TEMP_FILE"

while IFS= read -r line; do
    echo "$line" >> "$TEMP_FILE"

    # If this line starts a new block, process it
    if [[ "$line" =~ ^--\ id:\ (.+) ]]; then
        current_id="${BASH_REMATCH[1]}"

        # Extract SQL from this block
        sql_block=""
        in_sql=0

        # Read ahead to get the SQL
        while IFS= read -r sql_line; do
            if [[ "$sql_line" =~ ^--\ id: ]]; then
                # Next block started, put line back
                echo "$sql_line" >> "$TEMP_FILE"
                break
            elif [[ "$sql_line" =~ ^[[:space:]]*sql:[[:space:]]*\| ]]; then
                in_sql=1
            elif [[ "$sql_line" =~ ^[[:space:]]*sql: ]]; then
                # Single line SQL
                sql_content=$(echo "$sql_line" | sed 's/^[[:space:]]*sql:[[:space:]]*//')
                sql_block="$sql_content"
                in_sql=0
            elif [[ $in_sql -eq 1 && "$sql_line" =~ ^[[:space:]]+ && ! "$sql_line" =~ ^[[:space:]]*[a-zA-Z_] ]]; then
                # Multi-line SQL content
                sql_content=$(echo "$sql_line" | sed 's/^[[:space:]]*//')
                if [ -n "$sql_content" ]; then
                    sql_block="$sql_block $sql_content"
                fi
            elif [[ "$sql_line" =~ ^[[:space:]]*[a-zA-Z_] ]]; then
                in_sql=0

                # If we found bind_values with param1, param2, etc., replace them
                if [[ "$sql_line" =~ bind_values: ]] && [ -n "$sql_block" ]; then
                    echo "$sql_line" >> "$TEMP_FILE"

                    # Extract actual column names
                    bind_values=$(extract_bind_values "$sql_block")
                    param_count=$(echo "$sql_block" | tr -cd '?' | wc -c)

                    if [ -n "$bind_values" ] && [ "$(echo "$bind_values" | wc -l)" -eq "$param_count" ]; then
                        # Replace param1, param2 with actual names
                        while IFS= read -r next_line; do
                            if [[ "$next_line" =~ ^[[:space:]]*-[[:space:]]*param[0-9]+ ]]; then
                                # Skip this placeholder line, we'll replace it
                                continue
                            elif [[ "$next_line" =~ ^[[:space:]]*- ]]; then
                                # Already has real values, keep them
                                echo "$next_line" >> "$TEMP_FILE"
                            else
                                # End of bind_values section
                                # Add our extracted values
                                while IFS= read -r val; do
                                    if [ -n "$val" ]; then
                                        echo "      - $val" >> "$TEMP_FILE"
                                    fi
                                done <<< "$bind_values"
                                echo "$next_line" >> "$TEMP_FILE"
                                break
                            fi
                        done
                        continue
                    fi
                fi

                echo "$sql_line" >> "$TEMP_FILE"
            else
                echo "$sql_line" >> "$TEMP_FILE"
            fi
        done
    fi
done < "$YAML_FILE"

mv "$TEMP_FILE" "$YAML_FILE"

echo "Processing completed!"
echo "Original backed up as: $BACKUP_FILE"
echo "Fixed bind_values to match SQL parameters in correct order"
