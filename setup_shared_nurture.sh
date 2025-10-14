#!/bin/bash

# Shared Nurture Engine Setup Script
# This script sets up polymorphic nurture enrollments for Accounts

echo "=========================================="
echo "Shared Nurture Engine Setup"
echo "=========================================="
echo ""

cd "$(dirname "$0")"

echo "Step 1: Running database migration..."
echo "Making nurture_enrollments polymorphic..."
bundle exec rails db:migrate

if [ $? -eq 0 ]; then
    echo "✅ Migration completed successfully!"
    echo ""
    echo "Step 2: Checking migration status..."
    bundle exec rails db:migrate:status | tail -n 5
    echo ""
    echo "=========================================="
    echo "✅ Database Setup Complete!"
    echo "=========================================="
    echo ""
    echo "Backend is ready! Now update the frontend:"
    echo ""
    echo "1. Update AccountDetail.tsx:"
    echo "   - Add: import { AccountNurture } from '@/modules/accounts/components/AccountNurture'"
    echo "   - Change TabsList to grid-cols-7"
    echo "   - Add Nurture tab"
    echo ""
    echo "2. Restart Rails server:"
    echo "   - Press Ctrl+C"
    echo "   - Run: bundle exec rails s"
    echo ""
    echo "3. Test the implementation:"
    echo "   - Go to any Account"
    echo "   - Click 'Nurture' tab"
    echo "   - Enroll in a sequence"
    echo ""
    echo "See SHARED_NURTURE_SETUP_COMPLETE.md for full instructions"
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
