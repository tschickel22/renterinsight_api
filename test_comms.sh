#!/bin/bash
cd ~/src/renterinsight_api

echo "=== Testing Communications Controller ==="
bundle exec rspec spec/controllers/api/portal/communications_controller_spec.rb --format documentation
