#!/bin/bash
# Render release script - runs before each deployment

echo "🚀 Running release tasks..."

# Run migrations
echo "📊 Running database migrations..."
bundle exec rails db:migrate

# Seed database (only creates users if they don't exist)
echo "🌱 Seeding database..."
bundle exec rails db:seed

echo "✅ Release tasks complete!"
