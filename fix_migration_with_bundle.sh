#!/bin/bash
# Fix pending migration error with proper bundler setup

echo "🔧 Fixing pending migration error with Bundler..."
echo ""

# Navigate to the Rails app directory
cd ~/src/renterinsight_api

# First, ensure all gems are installed
echo "📦 Ensuring all gems are installed..."
bundle install

echo ""
echo "🚀 Running the pending migration..."
echo "Migration: 20251011164000_add_missing_fields_to_account_activities.rb"
echo ""

# Run the migration using bundle exec to ensure proper gem loading
bundle exec rails db:migrate

# Check migration status
echo ""
echo "📊 Checking migration status..."
bundle exec rails db:migrate:status | tail -10

echo ""
echo "✅ Migration complete!"
echo ""
echo "🚀 You can now restart your Rails server with:"
echo "   bundle exec rails s -b 0.0.0.0 -p 3001"
echo ""
echo "Or using the puma server directly:"
echo "   bundle exec puma -C config/puma.rb"
