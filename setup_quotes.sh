#!/bin/bash
# Quick setup script for Quotes module

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║         Quotes Module Backend Setup                      ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

cd "$(dirname "$0")"

# Step 1: Run migration
echo "📦 Step 1: Running database migration..."
bundle exec rails db:migrate
if [ $? -eq 0 ]; then
    echo "✅ Migration completed successfully!"
else
    echo "❌ Migration failed. Please check the error above."
    exit 1
fi
echo ""

# Step 2: Verify routes
echo "🔍 Step 2: Verifying routes..."
bundle exec rails routes | grep quotes
echo ""

# Step 3: Test API (optional)
echo "🧪 Step 3: Would you like to test the API? (y/n)"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    chmod +x test_quotes_api.sh
    ./test_quotes_api.sh
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                   Setup Complete! ✅                      ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "📚 Documentation: See QUOTES_BACKEND_IMPLEMENTATION.md"
echo "🚀 API is ready at: http://localhost:3001/api/v1/quotes"
echo ""
