#!/bin/bash

# Test script for bind_values functionality
echo "=== Testing Bind Values Extraction ==="

# Create comprehensive test file
cat > comprehensive_test.yaml << "EOF"
-- id: customerQuery
  sql: |
    SELECT c.*, a.address_line1, a.city
    FROM customers c
    LEFT JOIN addresses a ON c.id = a.customer_id
    WHERE 
      c.status = ? AND 
      c.created_date > ? AND
      a.country = ?
  meta:
    db: customer_db
    description: "Get customer with address info"

-- id: orderUpdate
  sql: |
    UPDATE orders 
    SET 
      status = ?,
      updated_by = ?,
      updated_date = CURRENT_TIMESTAMP
    WHERE 
      id = ? AND 
      customer_id = ?
  meta:
    db: orders_db

-- id: simpleSelect
  sql: SELECT * FROM products WHERE category = ? AND price > ?

-- id: noParametersQuery
  sql: SELECT COUNT(*) FROM users WHERE active = 1
  meta:
    db: user_db
    cache_ttl: 300

-- id: insertQuery
  sql: |
    INSERT INTO audit_log (user_id, action, timestamp, details)
    VALUES (?, ?, CURRENT_TIMESTAMP, ?)
EOF

echo "Created comprehensive test file:"
echo "================================="
cat comprehensive_test.yaml
echo "================================="

# Test the script
echo
echo "Running bind values extraction..."
./add_bind_final.sh comprehensive_test.yaml

echo
echo "Result after processing:"
echo "========================="
cat comprehensive_test.yaml
echo "========================="

echo
echo "Test completed!"
