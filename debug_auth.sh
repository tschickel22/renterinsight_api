#!/bin/bash
cd ~/src/renterinsight_api

echo "Testing auth with debug..."
bundle exec rspec spec/controllers/api/portal/auth_controller_spec.rb:87 --format documentation --backtrace | head -50
