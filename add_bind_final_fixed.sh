#!/bin/bash

# Improved script to add bind_values to YAML blocks based on SQL parameters
# This version correctly identifies ? parameters in SQL and preserves their order
# Usage: ./add_bind_final_fixed.sh input.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml_file>"
    exit 1
fi

# Create backup
BACKUP_FILE="$YAML_FILE.backup.$(date +%Y%m%d_%H%M%S)"
cp "$YAML_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"

# Function to extract bind values from SQL
extract_bind_values_from_sql() {
    local sql_content="$1"
    local bind_values=()

    # Remove comments and normalize whitespace
    sql_normalized=$(echo "$sql_content" | sed 's/--.*$//' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')

    # Find all ? parameters and their surrounding context
    echo "$sql_normalized" | grep -o -E '[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*[=<>!]+[[:space:]]*\?' | while read -r match; do
        # Extract the column name before the operator and ?
        column=$(echo "$match" | sed -E 's/^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*[=<>!]+[[:space:]]*\?.*$/\1/')
        echo "$column"
    done
}

# Function to count ? parameters in SQL
count_sql_parameters() {
    local sql_content="$1"
    echo "$sql_content" | grep -o '?' | wc -l
}

# Create temporary working directory
WORK_DIR=$(mktemp -d)
RESULT_FILE="$WORK_DIR/result.yaml"

# Process the YAML file block by block
awk '
BEGIN {
    in_block = 0
    in_sql = 0
    block_content = ""
    current_id = ""
    sql_content = ""
}

/^-- id:/ {
    # Process previous block if exists
    if (in_block && current_id != "") {
        print block_content > "'"$WORK_DIR"'/block_" current_id ".yaml"
        if (sql_content != "") {
            print sql_content > "'"$WORK_DIR"'/sql_" current_id ".txt"
        }
    }

    # Start new block
    in_block = 1
    in_sql = 0
    current_id = $3
    block_content = $0 "\n"
    sql_content = ""
    next
}

in_block && /^[[:space:]]*sql:[[:space:]]*\|/ {
    in_sql = 1
    block_content = block_content $0 "\n"
    next
}

in_block && /^[[:space:]]*sql:/ && !/\|/ {
    # Single line SQL
    sql_line = $0
    gsub(/^[[:space:]]*sql:[[:space:]]*/, "", sql_line)
    sql_content = sql_content sql_line " "
    block_content = block_content $0 "\n"
    next
}

in_block && in_sql && /^[[:space:]]+/ && !/^[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*:/ {
    # SQL content line (indented, not a YAML key)
    sql_line = $0
    gsub(/^[[:space:]]+/, "", sql_line)
    sql_content = sql_content sql_line " "
    block_content = block_content $0 "\n"
    next
}

in_block && /^[[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*:/ && !/^[[:space:]]*sql:/ {
    # End of SQL, start of other YAML properties
    in_sql = 0
    block_content = block_content $0 "\n"
    next
}

in_block {
    block_content = block_content $0 "\n"
}

END {
    # Process last block
    if (in_block && current_id != "") {
        print block_content > "'"$WORK_DIR"'/block_" current_id ".yaml"
        if (sql_content != "") {
            print sql_content > "'"$WORK_DIR"'/sql_" current_id ".txt"
        }
    }
}
' "$YAML_FILE"

# Now process each block
> "$RESULT_FILE"

for block_file in "$WORK_DIR"/block_*.yaml; do
    if [ ! -f "$block_file" ]; then
        continue
    fi

    # Get the ID from filename
    block_id=$(basename "$block_file" .yaml | sed 's/^block_//')
    sql_file="$WORK_DIR/sql_${block_id}.txt"

    if [ -f "$sql_file" ] && [ -s "$sql_file" ]; then
        # Count parameters in SQL
        param_count=$(count_sql_parameters "$(cat "$sql_file")")

        if [ "$param_count" -gt 0 ]; then
            echo "Processing block '$block_id' with $param_count parameters"

            # Extract bind values
            bind_values=$(extract_bind_values_from_sql "$(cat "$sql_file")")

            if [ -n "$bind_values" ]; then
                # Check if block already has bind_values
                if grep -q "bind_values:" "$block_file"; then
                    echo "  -> Block already has bind_values, skipping"
                    cat "$block_file" >> "$RESULT_FILE"
                else
                    # Add bind_values to the block
                    if grep -q "^[[:space:]]*meta:" "$block_file"; then
                        # Insert bind_values in existing meta section
                        awk '
                        /^[[:space:]]*meta:/ {
                            print $0
                            print "    bind_values:"
                            while ((getline bind_val < "'"$WORK_DIR"'/bind_" "'"$block_id"'") > 0) {
                                print "      - " bind_val
                            }
                            close("'"$WORK_DIR"'/bind_" "'"$block_id"'")
                            next
                        }
                        { print }
                        ' "$block_file" >> "$RESULT_FILE"

                        # Create bind values file
                        echo "$bind_values" > "$WORK_DIR/bind_${block_id}"
                    else
                        # Add new meta section
                        cat "$block_file" >> "$RESULT_FILE"
                        echo "  meta:" >> "$RESULT_FILE"
                        echo "    bind_values:" >> "$RESULT_FILE"
                        echo "$bind_values" | while read -r bind_val; do
                            if [ -n "$bind_val" ]; then
                                echo "      - $bind_val" >> "$RESULT_FILE"
                            fi
                        done
                    fi
                fi
            else
                echo "  -> No bind values could be extracted"
                cat "$block_file" >> "$RESULT_FILE"
            fi
        else
            echo "Processing block '$block_id' with no parameters"
            cat "$block_file" >> "$RESULT_FILE"
        fi
    else
        echo "Processing block '$block_id' with no SQL content"
        cat "$block_file" >> "$RESULT_FILE"
    fi

    echo "" >> "$RESULT_FILE"
done

# Replace original file
mv "$RESULT_FILE" "$YAML_FILE"

# Cleanup
rm -rf "$WORK_DIR"

echo "Bind values processing completed!"
echo "Original file backed up as: $BACKUP_FILE"
