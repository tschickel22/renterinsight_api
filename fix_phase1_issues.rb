# Quick fix script for remaining Phase 1 issues
puts "Checking Communication model for status methods..."

comm_file = 'app/models/communication.rb'
comm_content = File.read(comm_file)

unless comm_content.include?('def sent?')
  puts "Adding status query methods to Communication model..."
  
  # Find the right place to add (after enums, before end)
  insertion = <<~RUBY
  
  # Status query methods
  def sent?
    status == 'sent'
  end
  
  def delivered?
    status == 'delivered'
  end
  
  def failed?
    status == 'failed'
  end
  
  def opened?
    opened_at.present?
  end
  RUBY
  
  # Add before the last 'end'
  comm_content = comm_content.sub(/\nend\s*\z/, "\n#{insertion}\nend")
  File.write(comm_file, comm_content)
  puts "✅ Added status methods to Communication"
else
  puts "✅ Status methods already exist"
end

puts "\nDone! Now run: bundle exec rails runner fixed_phase1_test.rb"
