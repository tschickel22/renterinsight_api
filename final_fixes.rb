puts "Fixing remaining issues..."

# Fix 1: event_details -> metadata in CommunicationEvent
event_file = 'app/models/communication_event.rb'
if File.exist?(event_file)
  content = File.read(event_file)
  if content.include?('event_details')
    content = content.gsub('event_details', 'metadata')
    File.write(event_file, content)
    puts "✅ Fixed event_details -> metadata in CommunicationEvent"
  else
    puts "✅ CommunicationEvent already uses metadata"
  end
end

# Fix 2: Make status methods public in Communication
comm_file = 'app/models/communication.rb'
content = File.read(comm_file)

# Check if methods exist but are private
if content.match?(/private.*def sent\?/m)
  puts "Status methods are private, moving them to public section..."
  
  # Extract the status methods
  status_methods = content[/  # Status query methods.*?  def opened\?.*?  end/m]
  
  if status_methods
    # Remove from current location
    content = content.sub(status_methods, '')
    
    # Insert before private keyword
    content = content.sub(/\n  private/m, "\n#{status_methods}\n\n  private")
    
    File.write(comm_file, content)
    puts "✅ Moved status methods to public section"
  end
else
  puts "✅ Status methods are already public or need manual fix"
end

puts "\n✅ All fixes applied! Run test again:"
puts "   bundle exec rails runner fixed_phase1_test.rb"
