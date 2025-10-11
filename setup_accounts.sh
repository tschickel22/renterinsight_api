#!/bin/bash

echo "============================================="
echo "Setting up Accounts module..."
echo "============================================="

# Navigate to the Rails API directory
cd /home/tschi/src/renterinsight_api

# Run the migration
echo "Running database migration..."
bundle exec rails db:migrate

# Check if migration was successful
if [ $? -eq 0 ]; then
    echo "✓ Migration completed successfully"
    
    # Start the Rails server
    echo "Starting Rails server on port 3001..."
    bundle exec rails server -p 3001 -b 0.0.0.0 &
    
    echo "============================================="
    echo "✓ Accounts module setup complete!"
    echo "Rails server running on http://localhost:3001"
    echo "============================================="
else
    echo "✗ Migration failed. Please check the error messages above."
    exit 1
fi
