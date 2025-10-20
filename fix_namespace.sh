#!/bin/bash

# Fix the namespace issue in controllers

echo "Fixing namespace in controllers..."

# Update settings_controller.rb
sed -i 's/@company = Company.first/@company = ::Company.first/' app/controllers/api/settings_controller.rb

# Update uploads_controller.rb
sed -i 's/@company = Company.first/@company = ::Company.first/' app/controllers/api/uploads_controller.rb

echo "Fixed! Restart your Rails server."
