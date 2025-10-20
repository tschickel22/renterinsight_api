file = 'app/models/communication_preference.rb'
content = File.read(file)

# Replace the method
content.gsub!(
  /  def self\.can_send_to\?\(recipient:, channel:, category: nil\).*?preference&\.opted_in\?\n  end/m,
  <<~'RUBY'.chomp
  def self.can_send_to?(recipient:, channel:, category: nil)
    preference = where(
      recipient: recipient,
      channel: channel,
      category: category
    ).first
    
    # If no preference exists, default to opted in
    return true if preference.nil?
    
    # If preference exists, check if opted in
    preference.opted_in?
  end
  RUBY
)

File.write(file, content)
puts "✅ Fixed!"
