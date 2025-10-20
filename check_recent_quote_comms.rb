#!/usr/bin/env ruby
# Check recent Quote communications to see what happened
# Run with: bundle exec rails runner check_recent_quote_comms.rb

puts "=" * 80
puts "CHECKING RECENT QUOTE COMMUNICATIONS"
puts "=" * 80
puts

# Find the most recent quote communications
quote = Quote.find(22)
puts "Quote: #{quote.quote_number}"
puts "Status: #{quote.status}"
puts

recent_comms = Communication.where(communicable: quote)
  .where(channel: 'email')
  .order(created_at: :desc)
  .limit(5)

puts "Recent Email Communications for Quote ##{quote.id}:"
puts "-" * 80
puts

if recent_comms.empty?
  puts "❌ No email communications found!"
else
  recent_comms.each_with_index do |comm, i|
    puts "#{i + 1}. Communication ##{comm.id}"
    puts "   Created: #{comm.created_at}"
    puts "   Status: #{comm.status}"
    puts "   Provider: #{comm.provider}"
    puts "   To: #{comm.to_address}"
    puts "   From: #{comm.from_address}"
    puts "   Subject: #{comm.subject}"
    
    if comm.status == 'sent'
      puts "   Sent at: #{comm.sent_at}"
      puts "   External ID: #{comm.external_id}"
    elsif comm.status == 'failed'
      puts "   Failed at: #{comm.failed_at}"
      puts "   Error: #{comm.error_message}"
    elsif comm.status == 'pending'
      puts "   ⚠️  Status is PENDING (not sent yet!)"
      puts "   Scheduled for: #{comm.scheduled_for}" if comm.scheduled_for
      puts "   Scheduled status: #{comm.scheduled_status}" if comm.scheduled_status
    end
    
    puts
  end
end

puts "=" * 80
puts "CHECKING BACKGROUND JOBS"
puts "=" * 80
puts

# Check if there are any pending SendCommunicationJob jobs
begin
  if defined?(Sidekiq)
    puts "Sidekiq queue stats:"
    Sidekiq::Queue.all.each do |queue|
      puts "  #{queue.name}: #{queue.size} jobs"
    end
  else
    puts "Sidekiq not available (using ActiveJob default adapter)"
    puts "Check your Rails logs for job execution"
  end
rescue => e
  puts "Could not check background jobs: #{e.message}"
end
puts

puts "=" * 80
puts "DIAGNOSIS"
puts "=" * 80
puts

latest_comm = recent_comms.first

if latest_comm.nil?
  puts "❌ No communication records found!"
  puts "   The send might have failed before creating a Communication record."
elsif latest_comm.status == 'pending'
  puts "⚠️  Latest communication is PENDING (not sent yet!)"
  puts
  puts "This could mean:"
  puts "  1. It's queued for async sending via background job"
  puts "  2. It's scheduled for future delivery"
  puts "  3. It failed before the send could complete"
  puts
  puts "Check if send_async was set to true in the UI request."
  puts "If yes, check background job queue/logs to see if job ran."
elsif latest_comm.status == 'failed'
  puts "❌ Latest communication FAILED!"
  puts
  puts "Error: #{latest_comm.error_message}"
  puts
  puts "This is the actual error that prevented sending."
elsif latest_comm.status == 'sent'
  puts "✅ Latest communication is marked as SENT"
  puts
  puts "If the email didn't arrive, check:"
  puts "  1. Email spam/junk folder"
  puts "  2. Gmail account for sent mail"
  puts "  3. SMTP server logs"
  puts "  4. Email address is correct: #{latest_comm.to_address}"
  puts
  puts "External Message ID: #{latest_comm.external_id}"
  puts "(Use this to trace the email in Gmail/SMTP logs)"
end
puts

# Test sending right now to see if it works
puts "=" * 80
puts "TEST: Trying to send now (synchronous)"
puts "=" * 80
puts

begin
  service = QuoteSendingService.new(quote)
  result = service.send(
    delivery_methods: ['email'],
    to_email: 'tom@renterinsight.com',
    send_async: false  # Force synchronous
  )
  
  puts "Result:"
  puts "  Sent: #{result[:sent].length} communications"
  puts "  Failed: #{result[:failed].length} communications"
  puts "  Errors: #{result[:errors].inspect}"
  
  if result[:sent].any?
    puts
    puts "✅ Synchronous send worked!"
    puts "   Check your email inbox."
  else
    puts
    puts "❌ Synchronous send also failed"
    puts "   Errors: #{result[:errors]}"
  end
rescue => e
  puts "❌ Error during test: #{e.message}"
  puts "   #{e.backtrace.first(3).join("\n   ")}"
end
puts
