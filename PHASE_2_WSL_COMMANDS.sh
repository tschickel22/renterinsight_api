#!/bin/bash
# Phase 2 Setup Commands for WSL Ubuntu
# Run this from: /home/tschi/src/renterinsight_api

echo "================================================"
echo "PHASE 2 - SETUP AND TESTING COMMANDS"
echo "================================================"
echo ""

# Navigate to project directory
echo "Step 1: Navigate to project directory"
echo "--------------------------------------"
echo "cd /home/tschi/src/renterinsight_api"
echo ""

# Check Ruby and Rails versions
echo "Step 2: Verify environment"
echo "--------------------------------------"
echo "ruby -v"
echo "rails -v"
echo "bundle -v"
echo ""

# Install missing gems
echo "Step 3: Install dependencies"
echo "--------------------------------------"
echo "# Check if liquid and sidekiq are in Gemfile"
echo "grep -E '(liquid|sidekiq)' Gemfile"
echo ""
echo "# If not present, add them:"
echo "echo \"gem 'liquid'\" >> Gemfile"
echo "echo \"gem 'sidekiq'\" >> Gemfile"
echo ""
echo "# Install gems"
echo "bundle install"
echo ""

# Set up ActiveStorage
echo "Step 4: Configure ActiveStorage (if not already configured)"
echo "--------------------------------------"
echo "# Check if ActiveStorage is already installed"
echo "ls db/migrate/ | grep active_storage"
echo ""
echo "# If not present, install it:"
echo "rails active_storage:install"
echo ""

# Run migrations
echo "Step 5: Run database migrations"
echo "--------------------------------------"
echo "# Check pending migrations"
echo "rails db:migrate:status"
echo ""
echo "# Run all pending migrations"
echo "rails db:migrate"
echo ""
echo "# For test database"
echo "RAILS_ENV=test rails db:migrate"
echo ""

# Create Sidekiq config
echo "Step 6: Configure Sidekiq (if not exists)"
echo "--------------------------------------"
echo "# Check if config/sidekiq.yml exists"
echo "ls config/sidekiq.yml"
echo ""
echo "# If not, create it:"
cat << 'SIDEKIQ_CONFIG'
cat > config/sidekiq.yml << 'EOF'
:queues:
  - critical
  - communications
  - scheduled_communications
  - webhooks
  - default
:concurrency: 5
EOF
SIDEKIQ_CONFIG
echo ""

# Run tests
echo "Step 7: Run Phase 2 tests"
echo "--------------------------------------"
echo "# Run specific Phase 2 specs"
echo "bundle exec rspec spec/models/communication_template_spec.rb"
echo "bundle exec rspec spec/models/communication_attachment_spec.rb"
echo "bundle exec rspec spec/services/template_rendering_service_spec.rb"
echo "bundle exec rspec spec/services/attachment_service_spec.rb"
echo "bundle exec rspec spec/services/communication_analytics_spec.rb"
echo "bundle exec rspec spec/jobs/"
echo ""
echo "# Or run all specs"
echo "bundle exec rspec"
echo ""
echo "# Run with documentation format to see details"
echo "bundle exec rspec --format documentation"
echo ""

# Start Sidekiq
echo "Step 8: Start Sidekiq (in separate terminal)"
echo "--------------------------------------"
echo "# In a new WSL terminal window:"
echo "cd /home/tschi/src/renterinsight_api"
echo "bundle exec sidekiq"
echo ""

# Rails console testing
echo "Step 9: Test in Rails console"
echo "--------------------------------------"
echo "rails console"
echo ""
echo "# Then in console, try:"
cat << 'CONSOLE_TESTS'
# Create a template
template = CommunicationTemplate.create!(
  name: "Test Welcome Email",
  channel: :email,
  subject_template: "Welcome, {{ lead.first_name }}!",
  body_template: "Hi {{ lead.first_name }}, thanks for your interest!",
  category: :marketing,
  variables: { lead: ['first_name'] },
  active: true
)

# Find a lead to test with
lead = Lead.first

# Send a communication using the template
comm = CommunicationService.send_communication(
  communicable: lead,
  channel: :email,
  recipient: lead.email,
  template_id: template.id,
  template_variables: { lead: lead }
)

# Check analytics
stats = CommunicationAnalytics.aggregate_stats(
  start_date: 30.days.ago,
  end_date: Date.today
)
CONSOLE_TESTS
echo ""

# Optional: Create scheduled job runner
echo "Step 10: Process scheduled communications (optional - in production, use cron/whenever)"
echo "--------------------------------------"
echo "# In rails console or create a rake task:"
echo "rails runner 'SchedulingService.process_due_communications'"
echo ""

# Check logs
echo "Step 11: Monitor logs"
echo "--------------------------------------"
echo "# Watch Rails logs"
echo "tail -f log/development.log"
echo ""
echo "# Watch Sidekiq logs"
echo "tail -f log/sidekiq.log"
echo ""

echo "================================================"
echo "QUICK START COMMAND SEQUENCE"
echo "================================================"
cat << 'QUICKSTART'
cd /home/tschi/src/renterinsight_api
bundle install
rails active_storage:install 2>/dev/null || echo "ActiveStorage already installed"
rails db:migrate
RAILS_ENV=test rails db:migrate
bundle exec rspec spec/models/communication_template_spec.rb
bundle exec rspec spec/services/template_rendering_service_spec.rb
bundle exec rspec spec/jobs/
echo "✅ Phase 2 setup complete!"
QUICKSTART
echo ""

echo "================================================"
echo "TROUBLESHOOTING"
echo "================================================"
echo "# If migrations fail, check for conflicts:"
echo "rails db:migrate:status"
echo ""
echo "# If gems are missing:"
echo "bundle install"
echo ""
echo "# If tests fail, check test database is migrated:"
echo "RAILS_ENV=test rails db:migrate"
echo ""
echo "# Reset test database if needed:"
echo "RAILS_ENV=test rails db:reset"
echo ""
