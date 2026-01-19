#!/bin/bash

# Fixed script to add bind_values to YAML SQL blocks
# This script correctly extracts column names from SQL ? parameters in order
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

# Process the file using awk for reliable YAML parsing
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

function extract_column_names(sql) {
    # Extract column names that appear before ? parameters
    # Remove SQL comments and normalize whitespace
    gsub(/--.*$/, "", sql)
    gsub(/[[:space:]]+/, " ", sql)

    columns = ""

    # Handle INSERT statements specially
    if (match(sql, /INSERT[[:space:]]+INTO[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(([^)]+)\)/, arr)) {
        # Extract columns from INSERT INTO table (col1, col2, col3) VALUES (?, ?, ?)
        cols = arr[1]
        gsub(/[[:space:]]*,[[:space:]]*/, "\n", cols)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cols)
        return cols
    }

    # For SELECT/UPDATE/DELETE, find column = ? patterns in order
    # Split by spaces and look for patterns
    split(sql, words, " ")

    for (i = 1; i <= length(words); i++) {
        word = words[i]
        # Look for patterns like "column=" followed by "?" in next words
        if (match(word, /([a-zA-Z_][a-zA-Z0-9_.]*)=$/, col_match)) {
            column_name = col_match[1]
            # Check if next word or current word ends with ?
            if (i < length(words) && words[i+1] == "?" || match(word, /=\?$/)) {
                # Remove table prefix if present (e.g., c.status -> status)
                if (match(column_name, /\.([a-zA-Z_][a-zA-Z0-9_]*)$/, prefix_match)) {
                    column_name = prefix_match[1]
                }

                if (columns == "") {
                    columns = column_name
                } else {
                    columns = columns "\n" column_name
                }
            }
        }
        # Also handle "column = ?" with spaces
        else if (match(word, /^([a-zA-Z_][a-zA-Z0-9_.]*)$/) && i < length(words) && words[i+1] == "=" && i+2 <= length(words) && words[i+2] == "?") {
            column_name = word
            # Remove table prefix if present
            if (match(column_name, /\.([a-zA-Z_][a-zA-Z0-9_]*)$/, prefix_match)) {
                column_name = prefix_match[1]
            }

            if (columns == "") {
                columns = column_name
            } else {
                columns = columns "\n" column_name
            }
        }
    }

    return columns
}

function process_block() {
    # Count ? parameters
    param_count = gsub(/\?/, "?", sql_content)

    print "Processing " current_id ": " param_count " parameters" > "/dev/stderr"

    # Output the block
    printf "%s", current_block

    # Add bind_values if needed
    if (param_count > 0 && !has_bind_values) {
        # Extract column names
        columns = extract_column_names(sql_content)

        # Add bind_values section
        if (index(current_block, "meta:") > 0) {
            print "    bind_values:"
        } else {
            print "  meta:"
            print "    bind_values:"
        }

        # Add extracted columns or fallback names
        if (columns != "") {
            # Split columns and add them
            n = split(columns, col_array, "\n")
            if (n == param_count) {
                for (i = 1; i <= n; i++) {
                    if (col_array[i] != "") {
                        print "      - " col_array[i]
                    }
                }
                print "  -> Extracted: " columns > "/dev/stderr"
            } else {
                # Fallback to generic names if count does not match
                for (i = 1; i <= param_count; i++) {
                    print "      - param" i
                }
                print "  -> Using placeholder names (extraction count mismatch)" > "/dev/stderr"
            }
        } else {
            # Fallback to generic names if no extraction
            for (i = 1; i <= param_count; i++) {
                print "      - param" i
            }
            print "  -> Using placeholder names (no columns extracted)" > "/dev/stderr"
        }
    } else if (param_count == 0) {
        print "  -> No parameters found" > "/dev/stderr"
    } else {
        print "  -> Already has bind_values" > "/dev/stderr"
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

echo ""
echo "Bind values processing completed successfully!"
echo "Original file backed up as: $BACKUP_FILE"
echo ""
echo "Summary:"
echo "- Analyzed SQL statements for ? parameters"
echo "- Extracted actual column names where possible"
echo "- Used placeholder names when extraction failed"
echo "- Added bind_values sections where missing"
echo "- Preserved existing bind_values unchanged"
