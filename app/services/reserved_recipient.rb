# Addresses and phone numbers that can never belong to a real person, and the
# rule that the platform never hands them to a provider.
#
# Why: the demo company seeder used to invent customers at gmail.com, yahoo.com,
# hotmail.com and real lender domains. Every production seed run then emailed
# those strangers about their "home setup" (about 80 messages a run, with hard
# bounces against the shared SES account). Demo data now uses reserved names
# only, and this guard makes sure that even if someone presses Send on a demo
# record, or a demo's nurture step fires, nothing leaves the building.
#
# Reserved (RFC 2606 / RFC 6761, NANP):
#   example.com, example.net, example.org and any subdomain of them
#   any address under the .test, .example, .invalid or .localhost TLDs
#   any North American number on the 555 exchange (555-0100..0199 is set aside
#   for fiction; the rest of 555 is essentially unassigned, and older demo
#   companies used numbers like 555-4002)
module ReservedRecipient
  RESERVED_DOMAINS = %w[example.com example.net example.org].freeze
  RESERVED_TLDS    = %w[test example invalid localhost].freeze

  # Off in the test environment only: factories and specs address everything to
  # example.com and assert the provider was called. spec/services/
  # reserved_recipient_spec.rb turns it on to test the guard itself.
  mattr_accessor :enforced, default: !Rails.env.test?

  module_function

  def email?(address)
    addr = address.to_s
    addr = addr[/<([^>]*)>/, 1] || addr # "Name" <addr@domain>
    domain = addr.strip.downcase[/@([^@\s]+)\z/, 1]
    return false if domain.blank?

    domain = domain.delete_suffix('.')
    return true if RESERVED_TLDS.include?(domain.split('.').last)

    RESERVED_DOMAINS.any? { |d| domain == d || domain.end_with?(".#{d}") }
  end

  def phone?(number)
    digits = number.to_s.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    digits.length == 10 && digits[3, 3] == '555'
  end

  # The checks the send paths call. email?/phone? above only classify.
  def block?(channel, address)
    enforced && (channel.to_s == 'sms' ? phone?(address) : email?(address))
  end

  def block_email?(address)
    enforced && email?(address)
  end

  def block_phone?(number)
    enforced && phone?(number)
  end

  # Drops reserved entries from a list of addresses (String, comma separated
  # String, or Array). Returns the same shape it was given.
  def reject_emails(list)
    return list if list.blank? || !enforced

    if list.is_a?(Array)
      list.reject { |a| email?(a) }
    else
      list.to_s.split(',').map(&:strip).reject { |a| a.blank? || email?(a) }.join(', ').presence
    end
  end
end
