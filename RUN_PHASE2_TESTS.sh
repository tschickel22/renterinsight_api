#!/bin/bash
# Phase 2 Bug Fixes - Copy and paste these commands

# Navigate to project directory
cd /home/tschi/src/renterinsight_api

# Run the 5 previously failing tests
echo "=========================================="
echo "Testing the 5 fixed tests..."
echo "=========================================="
bundle exec rspec --format documentation \
  spec/services/communication_analytics_spec.rb:219 \
  spec/jobs/process_webhook_job_spec.rb:18 \
  spec/jobs/process_webhook_job_spec.rb:25 \
  spec/jobs/process_webhook_job_spec.rb:58 \
  spec/jobs/process_webhook_job_spec.rb:93

echo ""
echo "=========================================="
echo "Running FULL Phase 2 test suite..."
echo "=========================================="
bundle exec rspec --format progress \
  spec/models/communication_template_spec.rb \
  spec/services/template_rendering_service_spec.rb \
  spec/services/attachment_service_spec.rb \
  spec/services/communication_analytics_spec.rb \
  spec/jobs/

echo ""
echo "=========================================="
echo "COMPLETE! Check results above."
echo "=========================================="
