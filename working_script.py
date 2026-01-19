#!/usr/bin/env python3

"""
Simple Python script to add correct bind_values to YAML SQL blocks
This script properly extracts column names from SQL ? parameters in the correct order
Usage: python3 working_script.py input.yaml
"""

import os
import re
import sys
from datetime import datetime


def extract_bind_values_from_sql(sql):
    """Extract column names from SQL in the order they appear with ? parameters"""
    # Remove comments and normalize whitespace
    sql = re.sub(r"--.*$", "", sql, flags=re.MULTILINE)
    sql = " ".join(sql.split())  # Normalize whitespace

    bind_values = []

    # Handle INSERT statements
    if "INSERT" in sql.upper():
        insert_match = re.search(
            r"INSERT\s+INTO\s+\w+\s*\(([^)]+)\)", sql, re.IGNORECASE
        )
        if insert_match:
            columns = [col.strip() for col in insert_match.group(1).split(",")]
            # Count ? parameters to match
            param_count = sql.count("?")
            bind_values = columns[:param_count]
    else:
        # For SELECT/UPDATE/DELETE, find column = ? patterns in order
        pattern = r"(\w+(?:\.\w+)?)\s*[=<>!]+\s*\?"
        matches = re.findall(pattern, sql, re.IGNORECASE)
        for match in matches:
            # Remove table prefix (e.g., c.status -> status)
            column = match.split(".")[-1] if "." in match else match
            bind_values.append(column)

    return bind_values


def process_yaml_file(filename):
    """Process YAML file and add bind_values where needed"""

    # Create backup
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_file = f"{filename}.backup.{timestamp}"

    with open(filename, "r") as f:
        content = f.read()

    with open(backup_file, "w") as f:
        f.write(content)

    print(f"Created backup: {backup_file}")

    # Split into blocks by -- id: markers
    blocks = re.split(r"^-- id:", content, flags=re.MULTILINE)

    result_parts = []

    for i, block in enumerate(blocks):
        if i == 0:  # First part before any -- id:
            if block.strip():
                result_parts.append(block)
            continue

        # Add back the -- id: marker
        block = "-- id:" + block

        # Extract block ID
        id_match = re.search(r"-- id:\s*(\w+)", block)
        if not id_match:
            result_parts.append(block)
            continue

        block_id = id_match.group(1)

        # Extract SQL content
        sql_content = ""

        # Try multiline SQL first (with |)
        multiline_match = re.search(
            r"sql:\s*\|\s*\n(.*?)(?=\n\s*\w+:|$)", block, re.DOTALL
        )
        if multiline_match:
            sql_content = multiline_match.group(1)
            # Remove leading spaces from each line
            lines = sql_content.split("\n")
            sql_content = " ".join(line.strip() for line in lines if line.strip())
        else:
            # Try single line SQL
            singleline_match = re.search(r"sql:\s*([^\n]+)", block)
            if singleline_match:
                sql_content = singleline_match.group(1).strip()

        if sql_content:
            param_count = sql_content.count("?")
            print(f"Processing {block_id}: {param_count} parameters")

            if param_count > 0:
                # Check if bind_values already exists
                if "bind_values:" not in block:
                    # Extract bind values
                    bind_values = extract_bind_values_from_sql(sql_content)

                    # Ensure we have the right number of bind values
                    if len(bind_values) != param_count:
                        # Fallback to generic parameter names
                        bind_values = [f"param{i + 1}" for i in range(param_count)]
                        print(f"  -> Using placeholder names: {bind_values}")
                    else:
                        print(f"  -> Extracted: {bind_values}")

                    # Add bind_values
                    if "meta:" in block:
                        # Find meta section and add bind_values after it
                        meta_pos = block.find("meta:")
                        next_line_pos = block.find("\n", meta_pos)
                        if next_line_pos == -1:
                            next_line_pos = len(block)

                        before = block[:next_line_pos]
                        after = block[next_line_pos:]

                        bind_section = "\n    bind_values:"
                        for val in bind_values:
                            bind_section += f"\n      - {val}"

                        block = before + bind_section + after
                    else:
                        # Add new meta section at end of block
                        block = block.rstrip()
                        block += "\n  meta:"
                        block += "\n    bind_values:"
                        for val in bind_values:
                            block += f"\n      - {val}"
                        block += "\n"
                else:
                    print(f"  -> Already has bind_values")
            else:
                print(f"  -> No parameters found")

        result_parts.append(block)

    # Write the result back to the file
    with open(filename, "w") as f:
        f.write("".join(result_parts))

    print("\nProcessing completed successfully!")
    print(f"Original file backed up as: {backup_file}")
    print("\nSummary:")
    print("- Added bind_values sections where missing")
    print("- Extracted actual column names from SQL where possible")
    print("- Used placeholder names when extraction failed")
    print("- Preserved existing bind_values sections unchanged")


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 working_script.py input.yaml")
        sys.exit(1)

    yaml_file = sys.argv[1]

    if not os.path.exists(yaml_file):
        print(f"Error: File '{yaml_file}' not found")
        sys.exit(1)

    process_yaml_file(yaml_file)


if __name__ == "__main__":
    main()
