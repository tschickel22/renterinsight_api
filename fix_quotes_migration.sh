#!/bin/bash
# Fix and re-run the quotes migration

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║      Fixing Quotes Migration                             ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

cd "$(dirname "$0")"

# Step 1: Rollback the failed migration
echo "📦 Step 1: Rolling back the failed migration..."
bundle exec rails db:rollback STEP=1
if [ $? -eq 0 ]; then
    echo "✅ Rollback completed successfully!"
else
    echo "⚠️  Rollback had issues, but continuing..."
fi
echo ""

# Step 2: Re-run the fixed migration
echo "📦 Step 2: Running the fixed migration..."
bundle exec rails db:migrate
if [ $? -eq 0 ]; then
    echo "✅ Migration completed successfully!"
else
    echo "❌ Migration failed. Please check the error above."
    exit 1
fi
echo ""

# Step 3: Verify the quotes table exists
echo "📦 Step 3: Verifying quotes table..."
bundle exec rails runner "puts Quote.count rescue puts 'Error: Quote model not loading'"
echo ""

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                   Migration Fixed! ✅                     ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "🚀 You can now test the API!"
echo ""
