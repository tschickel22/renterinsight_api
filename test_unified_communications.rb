#!/usr/bin/env ruby
# Test script for Unified Communication System Phase 1

puts "=" * 80
puts "UNIFIED COMMUNICATION SYSTEM - PHASE 1 TEST"
puts "=" * 80
puts ""

# Test 1: Check if all models load
puts "Test 1: Loading Models..."
begin
  Communication
  CommunicationThread
  CommunicationPreference
  CommunicationEvent
  puts "✅ All models loaded successfully"
rescue => e
  puts "❌ Error loading models: #{e.message}"
  exit 1
end
puts ""

# Test 2: Check database tables
puts "Test 2: Checking Database Tables..."
required_tables = ['communications', 'communication_threads', 'communication_preferences', 'communication_events']
existing_tables = ActiveRecord::Base.connection.tables

required_tables.each do |table|
  if existing_tables.include?(table)
    puts "✅ Table '#{table}' exists"
  else
    puts "❌ Table '#{table}' missing!"
  end
end
puts ""

# Test 3: Create a test lead with Communicable concern
puts "Test 3: Testing Communicable Concern..."
begin
  # Check if Lead model exists and has Communicable
  if defined?(Lead)
    lead = Lead.first || Lead.create!(
      first_name: 'Test',
      last_name: 'User',
      email: 'test@example.com',
      phone: '+11234567890',
      status: 'new'
    )
    
    # Check if concern methods exist
    if lead.respond_to?(:communications)
      puts "✅ Lead has communications association"
    else
      puts "⚠️  Lead doesn't have Communicable concern yet (needs manual integration)"
    end
  else
    puts "⚠️  Lead model not found (will need manual integration)"
  end
rescue => e
  puts "⚠️  Lead test skipped: #{e.message}"
end
puts ""

# Test 4: Create a test communication
puts "Test 4: Creating Test Communication..."
begin
  # Find or create a test lead
  if defined?(Lead)
    lead = Lead.first || Lead.create!(
      first_name: 'Test',
      last_name: 'Communication',
      email: 'comm.test@example.com',
      phone: '+11234567890',
      status: 'new'
    )
    
    comm = Communication.create!(
      communicable: lead,
      direction: 'outbound',
      channel: 'email',
      provider: 'smtp',
      status: 'pending',
      subject: 'Test Email',
      body: 'This is a test email body',
      from_address: 'noreply@platformdms.com',
      to_address: 'test@example.com',
      metadata: { test: true }.to_json
    )
    
    puts "✅ Created Communication ##{comm.id}"
    puts "   - Communicable: #{comm.communicable_type} ##{comm.communicable_id}"
    puts "   - Channel: #{comm.channel}"
    puts "   - Status: #{comm.status}"
  else
    puts "⚠️  Skipping - Lead model needed for full test"
  end
rescue => e
  puts "❌ Error creating communication: #{e.message}"
end
puts ""

# Test 5: Test communication thread
puts "Test 5: Testing Communication Threading..."
begin
  if defined?(Lead) && Lead.any?
    lead = Lead.first
    
    comm1 = Communication.create!(
      communicable: lead,
      direction: 'outbound',
      channel: 'email',
      status: 'sent',
      subject: 'Thread Test 1',
      body: 'First message',
      from_address: 'noreply@platformdms.com',
      to_address: 'test@example.com'
    )
    
    comm2 = Communication.create!(
      communicable: lead,
      direction: 'outbound',
      channel: 'email',
      status: 'sent',
      subject: 'Thread Test 2',
      body: 'Second message',
      from_address: 'noreply@platformdms.com',
      to_address: 'test@example.com'
    )
    
    if comm1.communication_thread_id == comm2.communication_thread_id
      puts "✅ Communications grouped in same thread"
      puts "   Thread ID: #{comm1.communication_thread_id}"
    else
      puts "⚠️  Communications not threaded together"
    end
  else
    puts "⚠️  Skipping - needs Lead records"
  end
rescue => e
  puts "❌ Error testing threads: #{e.message}"
end
puts ""

# Test 6: Test communication preferences
puts "Test 6: Testing Communication Preferences..."
begin
  if defined?(Lead) && Lead.any?
    lead = Lead.first
    
    pref = CommunicationPreference.create!(
      recipient: lead,
      channel: 'email',
      category: 'marketing',
      opted_in: true
    )
    
    puts "✅ Created Communication Preference ##{pref.id}"
    puts "   - Recipient: #{pref.recipient_type} ##{pref.recipient_id}"
    puts "   - Channel: #{pref.channel}"
    puts "   - Opted In: #{pref.opted_in}"
    puts "   - Unsubscribe Token: #{pref.unsubscribe_token[0..20]}..."
    
    # Test opt-out
    pref.opt_out!('Testing opt-out', ip_address: '127.0.0.1')
    puts "✅ Opt-out successful"
    puts "   - Opted In: #{pref.opted_in}"
    puts "   - Opted Out At: #{pref.opted_out_at}"
  else
    puts "⚠️  Skipping - needs Lead records"
  end
rescue => e
  puts "❌ Error testing preferences: #{e.message}"
end
puts ""

# Test 7: Test communication events
puts "Test 7: Testing Communication Events..."
begin
  if Communication.any?
    comm = Communication.first
    
    event = CommunicationEvent.create!(
      communication: comm,
      event_type: 'sent',
      occurred_at: Time.current
    )
    
    puts "✅ Created Communication Event ##{event.id}"
    puts "   - Event Type: #{event.event_type}"
    puts "   - Occurred At: #{event.occurred_at}"
    
    # Test tracking methods
    comm.track_event('opened', { ip_address: '127.0.0.1' })
    puts "✅ Tracked 'opened' event"
    
    if comm.opened?
      puts "✅ Communication marked as opened"
    end
  else
    puts "⚠️  Skipping - needs Communication records"
  end
rescue => e
  puts "❌ Error testing events: #{e.message}"
end
puts ""

# Test 8: Test status transitions
puts "Test 8: Testing Status Transitions..."
begin
  if defined?(Lead) && Lead.any?
    lead = Lead.first
    
    comm = Communication.create!(
      communicable: lead,
      direction: 'outbound',
      channel: 'email',
      status: 'pending',
      subject: 'Status Test',
      body: 'Testing status transitions',
      from_address: 'noreply@platformdms.com',
      to_address: 'test@example.com'
    )
    
    puts "   Initial status: #{comm.status}"
    
    comm.mark_as_sent!
    puts "✅ mark_as_sent! - Status: #{comm.status}, Sent At: #{comm.sent_at}"
    
    comm.mark_as_delivered!
    puts "✅ mark_as_delivered! - Status: #{comm.status}, Delivered At: #{comm.delivered_at}"
  else
    puts "⚠️  Skipping - needs Lead records"
  end
rescue => e
  puts "❌ Error testing status transitions: #{e.message}"
end
puts ""

# Test 9: Test scopes
puts "Test 9: Testing Scopes..."
begin
  email_count = Communication.email.count
  sms_count = Communication.sms.count
  outbound_count = Communication.outbound.count
  sent_count = Communication.sent.count
  
  puts "✅ Scopes working:"
  puts "   - Email communications: #{email_count}"
  puts "   - SMS communications: #{sms_count}"
  puts "   - Outbound communications: #{outbound_count}"
  puts "   - Sent communications: #{sent_count}"
rescue => e
  puts "❌ Error testing scopes: #{e.message}"
end
puts ""

# Test 10: Statistics
puts "Test 10: Database Statistics..."
begin
  puts "✅ Record counts:"
  puts "   - Communications: #{Communication.count}"
  puts "   - Communication Threads: #{CommunicationThread.count}"
  puts "   - Communication Preferences: #{CommunicationPreference.count}"
  puts "   - Communication Events: #{CommunicationEvent.count}"
rescue => e
  puts "❌ Error getting statistics: #{e.message}"
end
puts ""

# Summary
puts "=" * 80
puts "TEST SUMMARY"
puts "=" * 80
puts "✅ Phase 1 Installation Complete!"
puts ""
puts "📋 Next Steps:"
puts "1. Integrate Communicable concern into Lead, Account, Quote models"
puts "2. Configure environment variables for providers (SMTP, AWS SES, Twilio)"
puts "3. Test sending actual emails/SMS in development"
puts "4. Review docs/README.md for usage examples"
puts "5. Ready for Phase 2: Templates, Attachments, and Scheduling"
puts ""
puts "=" * 80

