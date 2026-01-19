#!/bin/bash

# Ultra-simple working script to add bind_values to YAML SQL blocks
# This script works by processing the file in a straightforward way
# Usage: ./simple_working.sh input.yaml

YAML_FILE="$1"
if [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <yaml_file>"
    exit 1
fi

# Create backup
BACKUP_FILE="$YAML_FILE.backup.$(date +%Y%m%d_%H%M%S)"
cp "$YAML_FILE" "$BACKUP_FILE"
echo "Created backup: $BACKUP_FILE"

# Extract column names from SQL in the correct order
extract_columns() {
    local sql="$1"
    echo "$sql" | grep -oE '[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*=[[:space:]]*\?' | sed 's/[[:space:]]*=[[:space:]]*\?//' | sed 's/.*\.//'
}

# Process the file using awk (much more reliable than bash regex)
awk '
BEGIN {
    current_block = ""
    current_id = ""
    sql_content = ""
    in_multiline_sql = 0
    has_bind_values = 0
}

# New block starts
/^-- id:/ {
    # Process previous block
    if (current_id != "") {
        process_block()
    }

    # Start new block
    current_id = $3
    current_block = $0 "\n"
    sql_content = ""
    in_multiline_sql = 0
    has_bind_values = 0
    next
}

# SQL with pipe (multiline)
/^[[:space:]]*sql:[[:space:]]*\|/ {
    current_block = current_block $0 "\n"
    in_multiline_sql = 1
    next
}

# Single line SQL
/^[[:space:]]*sql:/ && !/\|/ {
    current_block = current_block $0 "\n"
    sql_line = $0
    gsub(/^[[:space:]]*sql:[[:space:]]*/, "", sql_line)
    sql_content = sql_line
    in_multiline_sql = 0
    next
}

# SQL content lines (indented, not YAML keys)
in_multiline_sql && /^[[:space:]]+/ && !/^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:/ {
    current_block = current_block $0 "\n"
    sql_line = $0
    gsub(/^[[:space:]]+/, "", sql_line)
    if (sql_content == "") {
        sql_content = sql_line
    } else {
        sql_content = sql_content " " sql_line
    }
    next
}

# bind_values already exists
/^[[:space:]]*bind_values:/ {
    has_bind_values = 1
    current_block = current_block $0 "\n"
    in_multiline_sql = 0
    next
}

# Other lines
{
    in_multiline_sql = 0
    current_block = current_block $0 "\n"
}

function process_block() {
    # Count ? parameters
    param_count = gsub(/\?/, "?", sql_content)

    print "Processing " current_id ": " param_count " parameters" > "/dev/stderr"

    # Output the block
    printf "%s", current_block

    # Add bind_values if needed
    if (param_count > 0 && !has_bind_values) {
        # Extract column names - simplified approach
        cmd = "echo \"" sql_content "\" | grep -oE \"[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*=[[:space:]]*\\?\" | sed \"s/[[:space:]]*=[[:space:]]*\\?//\" | sed \"s/.*\\.//"

        # Add bind_values section
        if (index(current_block, "meta:") > 0) {
            print "    bind_values:"
        } else {
            print "  meta:"
            print "    bind_values:"
        }

        # Add extracted columns or fallback names
        columns_added = 0
        while ((cmd | getline column) > 0) {
            print "      - " column
            columns_added++
        }
        close(cmd)

        # If no columns extracted, use generic names
        if (columns_added != param_count) {
            for (i = 1; i <= param_count; i++) {
                if (columns_added == 0 || i > columns_added) {
                    print "      - param" i
                }
            }
        }
    }

    print ""
}

END {
    # Process last block
    if (current_id != "") {
        process_block()
    }
}
' "$YAML_FILE" > "$YAML_FILE.new"

# Replace original file
mv "$YAML_FILE.new" "$YAML_FILE"

echo "Processing completed!"
echo "Original backed up as: $BACKUP_FILE"
