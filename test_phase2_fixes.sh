#!/bin/bash
# Test Phase 2 Fixes

echo "=========================================="
echo "Testing Phase 2 Communication Module Fixes"
echo "=========================================="
echo ""

cd /home/tschi/src/renterinsight_api

echo "Running fixed tests..."
echo ""

bundle exec rspec --format documentation \
  spec/services/communication_analytics_spec.rb:219 \
  spec/jobs/process_webhook_job_spec.rb:18 \
  spec/jobs/process_webhook_job_spec.rb:25 \
  spec/jobs/process_webhook_job_spec.rb:58 \
  spec/jobs/process_webhook_job_spec.rb:93

echo ""
echo "=========================================="
echo "Running full test suite for Phase 2..."
echo "=========================================="
echo ""

bundle exec rspec --format progress \
  spec/models/communication_template_spec.rb \
  spec/services/template_rendering_service_spec.rb \
  spec/services/attachment_service_spec.rb \
  spec/services/communication_analytics_spec.rb \
  spec/jobs/

echo ""
echo "=========================================="
echo "TEST SUMMARY"
echo "=========================================="
