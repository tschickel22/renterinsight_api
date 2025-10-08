#!/bin/bash

echo "=========================================="
echo "REMINDER PERSISTENCE DIAGNOSTIC SCRIPT"
echo "=========================================="
echo ""

echo "1. Checking Backend Routes..."
echo "----------------------------"
grep -n "reminders" config/routes.rb 2>/dev/null || echo "Routes file not found"
echo ""

echo "2. Checking Rails Controller..."
echo "--------------------------------"
if [ -f "app/controllers/api/crm/reminders_controller.rb" ]; then
    echo "Controller exists. Checking methods:"
    grep -n "def " app/controllers/api/crm/reminders_controller.rb
else
    echo "ERROR: Reminders controller not found"
fi
echo ""

echo "3. Checking Database Schema for Reminders..."
echo "---------------------------------------------"
grep -A 20 "create_table.*reminders" db/schema.rb 2>/dev/null || echo "No reminders table in schema"
echo ""

echo "4. Checking Frontend API Service..."
echo "------------------------------------"
echo "Checking dataService.ts for reminder endpoints:"
grep -n "reminder" src/modules/crm-prospecting/services/dataService.ts 2>/dev/null | head -20
echo ""

echo "5. Testing Backend API Directly..."
echo "----------------------------------"
echo "Checking if Rails server is running on port 3001..."
curl -s http://127.0.0.1:3001/api/crm/reminders -H "Accept: application/json" | head -c 500
echo ""
echo ""

echo "6. Checking for any reminder-related errors in Rails logs..."
echo "-------------------------------------------------------------"
if [ -f "log/development.log" ]; then
    echo "Last 20 reminder-related log entries:"
    grep -i "reminder" log/development.log | tail -20
else
    echo "No development log found"
fi
echo ""

echo "=========================================="
echo "DIAGNOSIS COMPLETE"
echo "=========================================="
