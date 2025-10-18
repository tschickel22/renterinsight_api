#!/bin/bash

echo "=================================="
echo "Contact Activities Migration"
echo "=================================="
echo ""

# Navigate to the Rails directory
cd ~/src/renterinsight_api

echo "📦 Running database migration..."
bundle exec rails db:migrate

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Migration completed successfully!"
    echo ""
    echo "📋 Verifying routes..."
    bundle exec rails routes | grep "contact_activities"
    echo ""
    echo "✅ Contact activities system is ready!"
    echo ""
    echo "📖 See CONTACT_ACTIVITIES_COMPLETE.md for full documentation"
else
    echo ""
    echo "❌ Migration failed. Please check the error message above."
    exit 1
fi
