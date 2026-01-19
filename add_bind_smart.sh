#!/bin/bash

# Smart script to add bind_values based on actual column names from SQL ? parameters
# This script analyzes SQL to extract column names that are used with ? parameters
# Usage: ./add_bind_smart.sh input.yaml

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
extract_bind_values() {
    local sql="$1"
    local bind_values=()

    # Normalize SQL - remove extra whitespace and newlines
    sql=$(echo "$sql" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # Find patterns like: column_name = ? or column_name > ? etc.
    # This regex looks for: word followed by optional spaces, then operator, then optional spaces, then ?
    local matches=$(echo "$sql" | grep -oE '[a-zA-Z_][a-zA-Z0-9_.]*[[:space:]]*[=<>!]+[[:space:]]*\?' | sed -E 's/[[:space:]]*[=<>!]+[[:space:]]*\?//')

    # Also look for INSERT VALUES patterns: VALUES (?, ?, ?)
    local insert_pattern=""
    if echo "$sql" | grep -qi "INSERT"; then
        # Extract table name and column list for INSERT statements
        local table_part=$(echo "$sql" | sed -nE 's/.*INSERT[[:space:]]+INTO[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(([^)]+)\).*/\1/pi')
        if [ -n "$table_part" ]; then
            # Count ? in VALUES clause
            local values_part=$(echo "$sql" | sed -nE 's/.*VALUES[[:space:]]*\(([^)]+)\).*/\1/pi')
            local question_count=$(echo "$values_part" | grep -o '?' | wc -l)

            # Extract column names from INSERT column list
            local insert_columns=$(echo "$table_part" | sed 's/[[:space:]]*,[[:space:]]*/\n/g' | sed 's/[[:space:]]*//')
            matches="$matches"$'\n'"$insert_columns"
        fi
    fi

    # Clean up matches and preserve order
    echo "$matches" | grep -v '^$' | head -20  # Limit to prevent runaway
}

# Process YAML file
python3 -c "
import re
import sys

def process_yaml(filename):
    with open(filename, 'r') as f:
        content = f.read()

    # Split by blocks (-- id: markers)
    blocks = re.split(r'^-- id:', content, flags=re.MULTILINE)

    result = []
    for i, block in enumerate(blocks):
        if i == 0:  # First split part might be empty or header
            if block.strip():
                result.append(block)
            continue

        # Add back the -- id: marker
        block = '-- id:' + block

        # Extract id, sql, and existing content
        id_match = re.search(r'-- id:\s*(\w+)', block)
        if not id_match:
            result.append(block)
            continue

        block_id = id_match.group(1)

        # Extract SQL content
        sql_match = re.search(r'sql:\s*\|?\s*\n?(.*?)(?=\n\s*meta:|$)', block, re.DOTALL)
        if not sql_match:
            # Try single line SQL
            sql_match = re.search(r'sql:\s*([^\n]+)', block)

        if sql_match:
            sql_content = sql_match.group(1).strip()
            # Clean up SQL - remove leading spaces from each line
            sql_lines = sql_content.split('\n')
            sql_content = ' '.join(line.strip() for line in sql_lines if line.strip())

            # Count ? parameters
            param_count = sql_content.count('?')
            print(f'Block {block_id}: Found {param_count} parameters', file=sys.stderr)

            if param_count > 0:
                # Extract bind values
                bind_values = extract_bind_values_from_sql(sql_content)

                # Check if bind_values already exists
                if 'bind_values:' not in block:
                    # Add bind_values
                    if 'meta:' in block:
                        # Insert into existing meta section
                        meta_pos = block.find('meta:')
                        before_meta = block[:meta_pos + 5]  # Include 'meta:'
                        after_meta = block[meta_pos + 5:]

                        bind_section = '\n    bind_values:'
                        for val in bind_values[:param_count]:  # Limit to actual param count
                            bind_section += f'\n      - {val}'

                        block = before_meta + bind_section + after_meta
                    else:
                        # Add meta section at end
                        block = block.rstrip()
                        block += '\n  meta:'
                        block += '\n    bind_values:'
                        for val in bind_values[:param_count]:
                            block += f'\n      - {val}'
                        block += '\n'

        result.append(block)

    return ''.join(result)

def extract_bind_values_from_sql(sql):
    '''Extract column names used with ? parameters from SQL'''
    # Remove comments
    sql = re.sub(r'--.*?$', '', sql, flags=re.MULTILINE)

    # Find column = ? patterns
    patterns = [
        r'(\w+)\s*[=<>!]+\s*\?',  # column = ?
        r'(\w+)\s+[<>]=?\s*\?',   # column >= ?
    ]

    bind_values = []
    for pattern in patterns:
        matches = re.findall(pattern, sql, re.IGNORECASE)
        bind_values.extend(matches)

    # Handle INSERT statements
    if 'INSERT' in sql.upper():
        insert_match = re.search(r'INSERT\s+INTO\s+\w+\s*\(([^)]+)\)', sql, re.IGNORECASE)
        if insert_match:
            columns = [col.strip() for col in insert_match.group(1).split(',')]
            # Count ? in VALUES
            values_match = re.search(r'VALUES\s*\(([^)]+)\)', sql, re.IGNORECASE)
            if values_match:
                question_count = values_match.group(1).count('?')
                bind_values.extend(columns[:question_count])

    # Remove duplicates while preserving order
    seen = set()
    unique_values = []
    for val in bind_values:
        if val not in seen:
            seen.add(val)
            unique_values.append(val)

    # If no values found, generate placeholders
    if not unique_values:
        param_count = sql.count('?')
        unique_values = [f'param{i+1}' for i in range(param_count)]

    return unique_values

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: python3 script.py input.yaml')
        sys.exit(1)

    filename = sys.argv[1]
    result = process_yaml(filename)

    with open(filename, 'w') as f:
        f.write(result)

    print('Processing completed!')

" "$YAML_FILE"

echo "Smart bind_values extraction completed!"
echo "Extracted actual column names from SQL where possible"
echo "Generated placeholders for undetectable parameters"
echo "Original file backed up as: $BACKUP_FILE"
