# Bind Values Extractor

## Overview
Automatically analyzes SQL queries in YAML files and adds bind_values sections based on column names found in SQL conditions like 'column_name = ?'.

## Usage
./add_bind_final.sh your_file.yaml

## Example Input:
-- id: myQuery
  sql: |
    SELECT * FROM users 
    WHERE status = ? AND created_date > ?
  meta:
    db: main

## Example Output:  
-- id: myQuery  
  sql: |
    SELECT * FROM users
    WHERE status = ? AND created_date > ?
  meta:
    bind_values:
      - status
      - created_date
    db: main

## Features:
- Extracts column names from 'column = ?' patterns
- Adds bind_values array under existing meta sections
- Creates meta section if it doesn't exist
- Handles both single-line and multi-line SQL
- Creates automatic backups

## Testing:
./test_bind_values.sh
