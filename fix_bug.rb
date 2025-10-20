#!/usr/bin/env ruby
file_path = 'app/models/communication_preference.rb'
content = File.read(file_path)

old_code = <<~CODE
  def self.can_send_to?(recipient:, channel:, category: nil)
    preference = where(
      recipient: recipient,
      channel: channel,
      category: category
    ).first
    
    # If no preference exists, default to opted in for transactional
    return true if preference.nil? && category == 'transactional'
    return true if preference.nil? && category.nil?
    
    preference&.opted_in?
  end
CODE

new_code = <<~CODE
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
CODE

content.gsub!(old_code.strip, new_code.strip)
File.write(file_path, content)
puts "✅ Fixed!"
