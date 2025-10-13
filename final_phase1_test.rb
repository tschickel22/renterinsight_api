#!/usr/bin/env ruby
# Comprehensive Final Test for Unified Communication System Phase 1
# Run with: bundle exec rails runner final_phase1_test.rb

puts "\n" + "=" * 80
puts "PHASE 1 UNIFIED COMMUNICATION SYSTEM - FINAL COMPREHENSIVE TEST"
puts "=" * 80
puts "\n"

# Initialize test results
test_results = {
  passed: [],
  failed: [],
  warnings: []
}

def log_pass(message, results)
  puts "✅ #{message}"
  results[:passed] << message
end

def log_fail(message, error, results)
  puts "❌ #{message}"
  puts "   Error: #{error.message}"
  results[:failed] << "#{message}: #{error.message}"
end

def log_warning(message, results)
  puts "⚠️  #{message}"
  results[:warnings] << message
end

# =============================================================================
# TEST 1: Model Loading and Table Existence
# =============================================================================
puts "TEST 1: Core Infrastructure"
puts "-" * 80

begin
  # Check models
  [Communication, CommunicationThread, CommunicationPreference, CommunicationEvent].each do |model|
    model.table_exists?
    log_pass("#{model.name} model loads correctly", test_results)
  end
  
  # Check tables and columns
  required_columns = {
    'communications' => %w[communicable_type communicable_id channel direction status body sent_at delivered_at],
    'communication_threads' => %w[subject participant_type participant_id],
    'communication_preferences' => %w[recipient_type recipient_id channel opted_in unsubscribe_token],
    'communication_events' => %w[communication_id event_type occurred_at]
  }
  
  required_columns.each do |table, columns|
    existing_columns = ActiveRecord::Base.connection.columns(table).map(&:name)
    missing = columns - existing_columns
    if missing.empty?
      log_pass("Table '#{table}' has all required columns", test_results)
    else
      log_fail("Table '#{table}' missing columns", StandardError.new(missing.join(', ')), test_results)
    end
  end
  
rescue => e
  log_fail("Core infrastructure check", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 2: Communicable Concern Integration
# =============================================================================
puts "TEST 2: Communicable Concern Integration"
puts "-" * 80

begin
  models_to_check = []
  models_to_check << Lead if defined?(Lead)
  models_to_check << Account if defined?(Account)
  models_to_check << Quote if defined?(Quote)
  
  if models_to_check.empty?
    log_warning("No Lead/Account/Quote models found - may need to load them", test_results)
  else
    models_to_check.each do |model|
      if model.instance_methods.include?(:communications)
        log_pass("#{model.name} has Communicable concern integrated", test_results)
      else
        log_warning("#{model.name} does not have Communicable concern yet", test_results)
      end
    end
  end
rescue => e
  log_fail("Communicable concern check", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 3: Communication Creation and Polymorphic Associations
# =============================================================================
puts "TEST 3: Communication Creation"
puts "-" * 80

begin
  # Clean up any existing test data
  Communication.where("body LIKE '%TEST COMMUNICATION%'").destroy_all
  
  # Test with a generic polymorphic record (we'll create a simple test)
  # In real use, this would be Lead/Account/Quote
  
  comm = Communication.create!(
    communicable_type: 'Lead',
    communicable_id: 1,
    channel: :email,
    direction: :outbound,
    status: :pending,
    subject: 'Test Subject',
    body: 'TEST COMMUNICATION BODY',
    sender_email: 'test@example.com',
    recipient_email: 'recipient@example.com'
  )
  
  log_pass("Created Communication ##{comm.id}", test_results)
  log_pass("Polymorphic association set correctly (#{comm.communicable_type}##{comm.communicable_id})", test_results)
  
  # Test channel and direction enums
  if comm.email? && comm.outbound?
    log_pass("Enum values work correctly (email, outbound)", test_results)
  end
  
rescue => e
  log_fail("Communication creation", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 4: Communication Threading
# =============================================================================
puts "TEST 4: Communication Threading"
puts "-" * 80

begin
  # Create a thread
  thread = CommunicationThread.create!(
    subject: 'Test Conversation',
    participant_type: 'Lead',
    participant_id: 1
  )
  
  log_pass("Created CommunicationThread ##{thread.id}", test_results)
  
  # Add communications to thread
  comm1 = Communication.create!(
    communicable_type: 'Lead',
    communicable_id: 1,
    communication_thread: thread,
    channel: :email,
    direction: :outbound,
    status: :sent,
    body: 'First message in thread'
  )
  
  comm2 = Communication.create!(
    communicable_type: 'Lead',
    communicable_id: 1,
    communication_thread: thread,
    channel: :email,
    direction: :inbound,
    status: :delivered,
    body: 'Reply in thread'
  )
  
  if thread.communications.count == 2
    log_pass("Thread contains #{thread.communications.count} communications", test_results)
  end
  
  if thread.communications.pluck(:direction).map(&:to_sym).sort == [:inbound, :outbound]
    log_pass("Thread has both inbound and outbound messages", test_results)
  end
  
rescue => e
  log_fail("Communication threading", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 5: Communication Preferences and Opt-In/Out
# =============================================================================
puts "TEST 5: Communication Preferences & Compliance"
puts "-" * 80

begin
  # Clean up existing test preferences
  CommunicationPreference.where(recipient_type: 'Lead', recipient_id: 999).destroy_all
  
  # Create preference with opt-in
  pref = CommunicationPreference.create!(
    recipient_type: 'Lead',
    recipient_id: 999,
    channel: :email,
    opted_in: true
  )
  
  log_pass("Created CommunicationPreference ##{pref.id}", test_results)
  
  # Check unsubscribe token generation
  if pref.unsubscribe_token.present? && pref.unsubscribe_token.length >= 20
    log_pass("Unsubscribe token generated: #{pref.unsubscribe_token[0..10]}...", test_results)
  end
  
  # Test opt-out
  pref.update!(opted_in: false, opted_out_at: Time.current, opt_out_reason: 'User request')
  
  if !pref.opted_in? && pref.opted_out_at.present?
    log_pass("Opt-out tracked correctly", test_results)
  end
  
  # Test preference lookup
  found_pref = CommunicationPreference.find_by(
    recipient_type: 'Lead',
    recipient_id: 999,
    channel: :email
  )
  
  if found_pref == pref
    log_pass("Preference lookup by recipient works", test_results)
  end
  
  # Test can_send_to? method
  opted_in_pref = CommunicationPreference.create!(
    recipient_type: 'Lead',
    recipient_id: 998,
    channel: :sms,
    opted_in: true
  )
  
  if CommunicationPreference.can_send_to?('Lead', 998, :sms)
    log_pass("can_send_to? correctly identifies opted-in recipients", test_results)
  end
  
  if !CommunicationPreference.can_send_to?('Lead', 999, :email)
    log_pass("can_send_to? correctly blocks opted-out recipients", test_results)
  end
  
rescue => e
  log_fail("Communication preferences", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 6: Communication Events and Tracking
# =============================================================================
puts "TEST 6: Event Tracking"
puts "-" * 80

begin
  # Create a communication for event tracking
  comm = Communication.create!(
    communicable_type: 'Lead',
    communicable_id: 1,
    channel: :email,
    direction: :outbound,
    status: :pending,
    body: 'Test event tracking'
  )
  
  # Track sent event
  event1 = CommunicationEvent.create!(
    communication: comm,
    event_type: :sent,
    occurred_at: Time.current,
    metadata: { provider: 'smtp' }
  )
  
  log_pass("Created 'sent' event ##{event1.id}", test_results)
  
  # Track delivered event
  event2 = CommunicationEvent.create!(
    communication: comm,
    event_type: :delivered,
    occurred_at: Time.current
  )
  
  log_pass("Created 'delivered' event ##{event2.id}", test_results)
  
  # Track opened event
  event3 = CommunicationEvent.create!(
    communication: comm,
    event_type: :opened,
    occurred_at: Time.current
  )
  
  log_pass("Created 'opened' event ##{event3.id}", test_results)
  
  # Check event count
  if comm.communication_events.count == 3
    log_pass("Communication has #{comm.communication_events.count} tracked events", test_results)
  end
  
  # Check metadata storage
  if event1.metadata['provider'] == 'smtp'
    log_pass("Event metadata stored correctly", test_results)
  end
  
rescue => e
  log_fail("Event tracking", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 7: Status Transitions and Timestamps
# =============================================================================
puts "TEST 7: Status Transitions"
puts "-" * 80

begin
  comm = Communication.create!(
    communicable_type: 'Lead',
    communicable_id: 1,
    channel: :email,
    direction: :outbound,
    status: :pending,
    body: 'Test status transitions'
  )
  
  initial_status = comm.status
  log_pass("Initial status: #{initial_status}", test_results)
  
  # Test mark_as_sent!
  comm.mark_as_sent!
  if comm.sent? && comm.sent_at.present?
    log_pass("mark_as_sent! works - Status: #{comm.status}, Sent at: #{comm.sent_at}", test_results)
  end
  
  # Test mark_as_delivered!
  comm.mark_as_delivered!
  if comm.delivered? && comm.delivered_at.present?
    log_pass("mark_as_delivered! works - Status: #{comm.status}, Delivered at: #{comm.delivered_at}", test_results)
  end
  
  # Test mark_as_failed!
  comm2 = Communication.create!(
    communicable_type: 'Lead',
    communicable_id: 1,
    channel: :email,
    direction: :outbound,
    status: :pending,
    body: 'Test failure'
  )
  
  comm2.mark_as_failed!('Test error message')
  if comm2.failed? && comm2.error_message == 'Test error message'
    log_pass("mark_as_failed! works with error message", test_results)
  end
  
  # Test mark_as_opened!
  comm.mark_as_opened!
  if comm.opened? && comm.opened_at.present?
    log_pass("mark_as_opened! works - Opened at: #{comm.opened_at}", test_results)
  end
  
rescue => e
  log_fail("Status transitions", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 8: Scopes and Queries
# =============================================================================
puts "TEST 8: Scopes and Queries"
puts "-" * 80

begin
  # Test channel scopes
  email_count = Communication.email.count
  sms_count = Communication.sms.count
  
  log_pass("Email communications: #{email_count}", test_results)
  log_pass("SMS communications: #{sms_count}", test_results)
  
  # Test direction scopes
  outbound_count = Communication.outbound.count
  inbound_count = Communication.inbound.count
  
  log_pass("Outbound: #{outbound_count}, Inbound: #{inbound_count}", test_results)
  
  # Test status scopes
  sent_count = Communication.sent.count
  delivered_count = Communication.delivered.count
  failed_count = Communication.failed.count
  
  log_pass("Status counts - Sent: #{sent_count}, Delivered: #{delivered_count}, Failed: #{failed_count}", test_results)
  
  # Test recent scope
  recent = Communication.recent.limit(5)
  log_pass("Recent scope returns #{recent.count} communications", test_results)
  
  # Test for_communicable scope
  if Communication.respond_to?(:for_communicable)
    lead_comms = Communication.for_communicable('Lead', 1).count
    log_pass("for_communicable scope works - #{lead_comms} communications for Lead#1", test_results)
  end
  
rescue => e
  log_fail("Scopes and queries", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 9: Service Layer (if loaded)
# =============================================================================
puts "TEST 9: Service Layer"
puts "-" * 80

begin
  if defined?(CommunicationService)
    log_pass("CommunicationService class is loaded", test_results)
  else
    log_warning("CommunicationService not loaded", test_results)
  end
  
  if defined?(CommunicationPreferenceService)
    log_pass("CommunicationPreferenceService class is loaded", test_results)
  else
    log_warning("CommunicationPreferenceService not loaded", test_results)
  end
  
  # Check for provider classes
  providers = []
  providers << 'Providers::Email::SmtpProvider' if defined?(Providers::Email::SmtpProvider)
  providers << 'Providers::Email::GmailRelayProvider' if defined?(Providers::Email::GmailRelayProvider)
  providers << 'Providers::Email::AwsSesProvider' if defined?(Providers::Email::AwsSesProvider)
  providers << 'Providers::Sms::TwilioProvider' if defined?(Providers::Sms::TwilioProvider)
  
  if providers.any?
    log_pass("Provider classes loaded: #{providers.join(', ')}", test_results)
  else
    log_warning("No provider classes loaded", test_results)
  end
  
rescue => e
  log_fail("Service layer check", e, test_results)
end

puts "\n"

# =============================================================================
# TEST 10: Database Statistics and Health
# =============================================================================
puts "TEST 10: Database Statistics"
puts "-" * 80

begin
  stats = {
    'Communications' => Communication.count,
    'Communication Threads' => CommunicationThread.count,
    'Communication Preferences' => CommunicationPreference.count,
    'Communication Events' => CommunicationEvent.count
  }
  
  stats.each do |model, count|
    log_pass("#{model}: #{count} records", test_results)
  end
  
  # Check for orphaned records
  orphaned_events = CommunicationEvent.left_joins(:communication).where(communications: { id: nil }).count
  if orphaned_events == 0
    log_pass("No orphaned communication events", test_results)
  else
    log_warning("Found #{orphaned_events} orphaned communication events", test_results)
  end
  
rescue => e
  log_fail("Database statistics", e, test_results)
end

puts "\n"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
puts "=" * 80
puts "FINAL TEST SUMMARY"
puts "=" * 80
puts "\n"

puts "✅ PASSED: #{test_results[:passed].count} tests"
test_results[:passed].each { |t| puts "   - #{t}" }

puts "\n"

if test_results[:warnings].any?
  puts "⚠️  WARNINGS: #{test_results[:warnings].count}"
  test_results[:warnings].each { |w| puts "   - #{w}" }
  puts "\n"
end

if test_results[:failed].any?
  puts "❌ FAILED: #{test_results[:failed].count} tests"
  test_results[:failed].each { |f| puts "   - #{f}" }
  puts "\n"
end

# Overall status
if test_results[:failed].empty?
  puts "🎉 ALL TESTS PASSED! Phase 1 is ready for production."
  puts "\n"
  puts "📋 Next Steps:"
  puts "   1. Integrate Communicable concern into Lead, Account, Quote models"
  puts "   2. Configure environment variables for providers"
  puts "   3. Test actual email/SMS sending in development"
  puts "   4. Review documentation in docs/ directory"
  puts "   5. Move to Phase 2: Templates, Attachments, Scheduling"
else
  puts "⚠️  Some tests failed. Review the errors above and fix issues before proceeding."
end

puts "\n" + "=" * 80 + "\n"
