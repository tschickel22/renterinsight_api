#!/bin/bash
# Comprehensive fix for Rails migration error

echo "==================================================="
echo "🔧 FIXING RAILS MIGRATION ERROR"
echo "==================================================="
echo ""

# Navigate to the Rails app directory
cd ~/src/renterinsight_api

echo "📍 Current directory: $(pwd)"
echo ""

# Method 1: Try using bin/rails (recommended)
echo "Method 1: Using bin/rails..."
if [ -f "bin/rails" ]; then
    echo "✓ Found bin/rails"
    echo "Running migration..."
    ./bin/rails db:migrate
    
    if [ $? -eq 0 ]; then
        echo "✅ Migration successful using bin/rails!"
        echo ""
        echo "📊 Current migration status:"
        ./bin/rails db:migrate:status | tail -10
        echo ""
        echo "🚀 Restart your server with:"
        echo "   ./bin/rails s -b 0.0.0.0 -p 3001"
        exit 0
    else
        echo "⚠️ bin/rails failed, trying alternative method..."
    fi
fi

# Method 2: Try using bundle exec
echo ""
echo "Method 2: Using bundle exec..."
echo "First, installing gems..."
bundle install

echo ""
echo "Running migration with bundle exec..."
bundle exec rails db:migrate

if [ $? -eq 0 ]; then
    echo "✅ Migration successful using bundle exec!"
    echo ""
    echo "📊 Current migration status:"
    bundle exec rails db:migrate:status | tail -10
    echo ""
    echo "🚀 Restart your server with:"
    echo "   bundle exec rails s -b 0.0.0.0 -p 3001"
    exit 0
else
    echo "⚠️ bundle exec also failed"
fi

# Method 3: Try using rake
echo ""
echo "Method 3: Using bundle exec rake..."
bundle exec rake db:migrate

if [ $? -eq 0 ]; then
    echo "✅ Migration successful using rake!"
    echo ""
    echo "📊 Current migration status:"
    bundle exec rake db:migrate:status | tail -10
    echo ""
    echo "🚀 Restart your server with:"
    echo "   bundle exec rails s -b 0.0.0.0 -p 3001"
    exit 0
fi

echo ""
echo "❌ All methods failed. Please check your Ruby/Rails installation:"
echo "   ruby --version"
echo "   bundle --version"
echo "   gem list rails"
