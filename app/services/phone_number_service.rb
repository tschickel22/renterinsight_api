# frozen_string_literal: true

class PhoneNumberService
  # Normalize phone number to E.164 format
  # Automatically adds +1 for US/Canada numbers
  def self.normalize(phone)
    return nil if phone.blank?
    
    # If already starts with +, return as-is
    return phone if phone.to_s.strip.start_with?('+')
    
    # Remove all non-digit characters
    digits = digits_only(phone)
    return nil if digits.blank?
    
    # If starts with 1 and has 11 digits, add + prefix
    return "+#{digits}" if digits.length == 11 && digits.start_with?('1')
    
    # If 10 digits, assume US/Canada and add +1
    return "+1#{digits}" if digits.length == 10
    
    # Otherwise just add + prefix
    "+#{digits}"
  end
  
  # Extract only digits from phone number
  def self.digits_only(phone)
    return nil if phone.blank?
    phone.to_s.gsub(/\D/, '')
  end
  
  # Format phone for display (e.g., +1 (303) 570-9810)
  def self.format_display(phone)
    normalized = normalize(phone)
    return phone if normalized.blank?
    
    digits = digits_only(normalized)
    
    # US/Canada format
    if digits.length == 11 && digits.start_with?('1')
      area = digits[1..3]
      prefix = digits[4..6]
      line = digits[7..10]
      return "+1 (#{area}) #{prefix}-#{line}"
    end
    
    # Default: just return normalized
    normalized
  end
end
