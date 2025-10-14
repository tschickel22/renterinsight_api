#!/bin/bash
# Fix pending migration error for account_activities

echo "🔧 Fixing pending migration error..."
echo "Running migration: 20251011164000_add_missing_fields_to_account_activities.rb"
echo ""

# Navigate to the Rails app directory
cd ~/src/renterinsight_api

# Run the pending migration
rails db:migrate

# Check migration status
echo ""
echo "📊 Checking migration status..."
rails db:migrate:status | tail -5

echo ""
echo "✅ Migration complete!"
echo ""
echo "🚀 You can now restart your Rails server:"
echo "   rails s -b 0.0.0.0 -p 3001"
echo ""
echo "Or if you're using Puma directly:"
echo "   bundle exec puma -C config/puma.rb"
