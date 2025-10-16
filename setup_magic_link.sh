#!/bin/bash

# Magic Link Migration and Setup Script
echo "🔧 Setting up Magic Link for Admin Users..."
echo "=" | head -c 60 | tr '\n' '='
echo ""

# Navigate to Rails directory
cd ~/src/renterinsight_api

echo "📦 Step 1: Running database migration..."
bundle exec rails db:migrate

echo ""
echo "✅ Magic Link setup complete!"
echo ""
echo "🎉 What's been added:"
echo "   • magic_link_token column to users table"
echo "   • magic_link_expires_at column to users table"
echo "   • Unique index on magic_link_token"
echo ""
echo "📧 The magic link mailer is configured to use Platform Email Settings"
echo ""
echo "🧪 To test:"
echo "   1. Go to /magic-link, /admin/magic-link, or /client/magic-link"
echo "   2. Enter an email (admin or client)"
echo "   3. Check email for magic link"
echo "   4. Click link → automatic login!"
echo ""
echo "=" | head -c 60 | tr '\n' '='
echo ""
