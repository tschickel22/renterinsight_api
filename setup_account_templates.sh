#!/bin/bash

# Account Templates & Communications Setup Script
# This script runs the migration to add account_id to communication_logs

echo "=========================================="
echo "Account Templates Setup"
echo "=========================================="
echo ""

cd "$(dirname "$0")"

echo "Step 1: Running database migration..."
bundle exec rails db:migrate

if [ $? -eq 0 ]; then
    echo "✅ Migration completed successfully!"
    echo ""
    echo "Step 2: Checking migration status..."
    bundle exec rails db:migrate:status | tail -n 5
    echo ""
    echo "=========================================="
    echo "✅ Setup Complete!"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "1. Restart your Rails server"
    echo "2. Navigate to Accounts page"
    echo "3. Click the 'Templates' tab"
    echo "4. Create your first template!"
    echo ""
else
    echo "❌ Migration failed!"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check the error message above"
    echo "2. Verify database connection"
    echo "3. Run: bundle exec rails db:migrate:status"
    echo ""
    exit 1
fi
