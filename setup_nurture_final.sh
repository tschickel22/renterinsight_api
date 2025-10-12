#!/bin/bash

echo "================================================"
echo "  Shared Nurture Engine - Final Setup"
echo "================================================"
echo ""
echo "This will complete the nurture engine setup."
echo ""

# Navigate to Rails directory
cd "$(dirname "$0")"

echo "Step 1: Running database migration..."
echo "--------------------------------------"
bundle exec rails db:migrate

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Migration completed successfully!"
    echo ""
    echo "Step 2: Checking migration status..."
    echo "--------------------------------------"
    bundle exec rails db:migrate:status | grep "nurture"
    echo ""
    echo "================================================"
    echo "  ✅ Setup Complete!"
    echo "================================================"
    echo ""
    echo "🎉 Shared Nurture Engine is ready!"
    echo ""
    echo "Next steps:"
    echo "1. Restart Rails server (if running)"
    echo "2. Go to any Account"
    echo "3. Click 'Nurture' tab"
    echo "4. Enroll the account in a sequence"
    echo ""
    echo "📖 Documentation:"
    echo "   - Quick Start: NURTURE_FINAL_SETUP.md"
    echo "   - Full Guide:  SHARED_NURTURE_SETUP_COMPLETE.md"
    echo "   - Quick Ref:   NURTURE_QUICK_REFERENCE.md"
    echo ""
else
    echo ""
    echo "❌ Migration failed!"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check the error above"
    echo "2. Verify database connection"
    echo "3. Try: bundle exec rails db:rollback"
    echo "4. Then re-run this script"
    echo ""
    exit 1
fi
