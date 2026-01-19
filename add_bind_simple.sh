#!/bin/bash

# Simple script to add bind_values based on ? parameter count in SQL
# Usage: ./add_bind_simple.sh input.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml_file>"
    exit 1
fi

# Create backup
BACKUP_FILE="$YAML_FILE.backup.$(date +%Y%m%d_%H%M%S)"
cp "$YAML_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"

# Temporary files
TEMP_FILE=$(mktemp)
OUTPUT_FILE=$(mktemp)

# Process each block
awk '
BEGIN {
    in_block = 0
    in_sql = 0
    block_lines = ""
    sql_content = ""
    current_id = ""
    param_count = 0
}

/^-- id:/ {
    # Process previous block
    if (in_block) {
        process_block()
    }

    # Start new block
    in_block = 1
    in_sql = 0
    current_id = $3
    block_lines = $0 "\n"
    sql_content = ""
    param_count = 0
    next
}

in_block && /^[[:space:]]*sql:[[:space:]]*\|/ {
    in_sql = 1
    block_lines = block_lines $0 "\n"
    next
}

in_block && /^[[:space:]]*sql:/ && !/\|/ {
    # Single line SQL
    sql_line = $0
    gsub(/^[[:space:]]*sql:[[:space:]]*/, "", sql_line)
    sql_content = sql_content " " sql_line
    block_lines = block_lines $0 "\n"
    in_sql = 0
    next
}

in_block && in_sql && /^[[:space:]]+/ && !/^[[:space:]]*[a-zA-Z_]/ {
    # Multi-line SQL content
    sql_content = sql_content " " $0
    block_lines = block_lines $0 "\n"
    next
}

in_block && /^[[:space:]]*meta:/ {
    in_sql = 0
    block_lines = block_lines $0 "\n"
    next
}

in_block {
    in_sql = 0
    block_lines = block_lines $0 "\n"
}

function process_block() {
    # Count ? parameters
    param_count = gsub(/\?/, "?", sql_content)

    print "Processing block: " current_id " with " param_count " parameters" > "/dev/stderr"

    # Output the block
    printf "%s", block_lines

    # Add bind_values if needed and not already present
    if (param_count > 0 && block_lines !~ /bind_values:/) {
        if (block_lines ~ /meta:/) {
            # Add to existing meta section
            print "    bind_values:"
            for (i = 1; i <= param_count; i++) {
                print "      - param" i
            }
        } else {
            # Add new meta section
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
    if (in_block) {
        process_block()
    }
}
' "$YAML_FILE" > "$OUTPUT_FILE"

# Replace original file
mv "$OUTPUT_FILE" "$YAML_FILE"

echo "Processing completed!"
echo "Generated placeholder bind_values (param1, param2, etc.)"
echo "Please review and rename parameters to match your SQL columns"
echo "Original file backed up as: $BACKUP_FILE"
