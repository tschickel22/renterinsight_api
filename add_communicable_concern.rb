#!/usr/bin/env ruby
# Script to add Communicable concern to Lead, Account, and Quote models

puts "Adding Communicable concern to models..."
puts "=" * 60

models = ['lead', 'account', 'quote']

models.each do |model_name|
  file_path = "app/models/#{model_name}.rb"
  
  unless File.exist?(file_path)
    puts "⚠️  #{model_name.capitalize} model not found at #{file_path}"
    next
  end
  
  content = File.read(file_path)
  
  # Check if already includes Communicable
  if content.include?('include Communicable')
    puts "✅ #{model_name.capitalize} already has Communicable concern"
    next
  end
  
  # Find the class definition line
  if content =~ /^class #{model_name.capitalize}\b.*$/i
    # Add include right after the class definition
    updated_content = content.sub(
      /^(class #{model_name.capitalize}\b.*\n)/i,
      "\\1  include Communicable\n"
    )
    
    File.write(file_path, updated_content)
    puts "✅ Added Communicable concern to #{model_name.capitalize}"
  else
    puts "⚠️  Could not find class definition in #{model_name.capitalize}"
  end
end

puts ""
puts "=" * 60
puts "✅ Done! Run the test again:"
puts "   bundle exec rails runner fixed_phase1_test.rb"
puts "=" * 60
