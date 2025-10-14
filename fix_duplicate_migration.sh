#!/bin/bash
# Fix duplicate migration issue

cd /home/tschi/src/renterinsight_api

echo "🔍 Checking for duplicate migrations..."
ls -la db/migrate/*buyer_portal_accesses*

echo ""
echo "🗑️  Removing duplicate migration..."
rm -f db/migrate/20251013214004_create_buyer_portal_accesses.rb

echo ""
echo "✅ Checking remaining migrations..."
ls -la db/migrate/*buyer_portal_accesses*

echo ""
echo "✅ Fixed! Now run the tests again."
