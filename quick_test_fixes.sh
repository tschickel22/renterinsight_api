#!/bin/bash
# Quick test of Phase 2 fixes

cd /home/tschi/src/renterinsight_api

echo "Testing Phase 2 fixes..."
echo ""

bundle exec rspec --format documentation \
  spec/services/communication_analytics_spec.rb:219 \
  spec/jobs/process_webhook_job_spec.rb:18 \
  spec/jobs/process_webhook_job_spec.rb:25 \
  spec/jobs/process_webhook_job_spec.rb:58 \
  spec/jobs/process_webhook_job_spec.rb:93

echo ""
echo "If all 5 tests passed, run full suite with:"
echo "bundle exec rspec spec/models/communication_template_spec.rb spec/services/ spec/jobs/"
