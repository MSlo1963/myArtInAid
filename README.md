# myArtIntAid - Bind Values Extractor

## Overview
This project contains bash scripts to automatically extract bind values from SQL queries in YAML files and add them to the meta section.

## Main Files

### Scripts
- **add_bind_final.sh** - Main script to add bind_values to YAML files
- **test_bind_values.sh** - Comprehensive test suite
- **extract_bind_values.sh** - Simple extraction demo script

### Documentation  
- **BIND_VALUES_README.md** - Detailed usage instructions
- **README.md** - This file

### Test Files
- **test_sql.yaml** - Basic test YAML file
- **comprehensive_test.yaml** - Complex test scenarios
- **test_sql_demo.yaml** - Demo result file

## Quick Start

1. Run the main script:
```bash
./add_bind_final.sh your_file.yaml
```

2. Run tests:
```bash  
./test_bind_values.sh
```

## Features
- Extracts column names from 'column = ?' SQL patterns
- Adds bind_values arrays under meta sections
- Creates backups automatically
- Handles complex SQL queries (SELECT, UPDATE, INSERT)
- Preserves existing YAML structure

## Example
Input SQL: `WHERE id = ? AND status = ?`
Output bind_values: `[id, status]`

