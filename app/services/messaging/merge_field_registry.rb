module Messaging
  module MergeFieldRegistry
    UNIVERSAL_FIELDS = [
      { key: 'first_name', label: 'First name', group: 'Recipient', sample: 'Sarah', available_for: %w[Lead Contact], channels: %w[email sms] },
      { key: 'last_name', label: 'Last name', group: 'Recipient', sample: 'Johnson', available_for: %w[Lead Contact], channels: %w[email sms] },
      { key: 'full_name', label: 'Full name', group: 'Recipient', sample: 'Sarah Johnson', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'email', label: 'Email address', group: 'Recipient', sample: 'sarah@example.com', available_for: %w[Lead Contact], channels: %w[email] },
      { key: 'phone', label: 'Phone number', group: 'Recipient', sample: '(303) 555-0123', available_for: %w[Lead Contact], channels: %w[sms] }
    ].freeze

    REP_FIELDS = [
      { key: 'rep_name', label: 'Sales rep name', group: 'Sales rep', sample: 'Tom Schickel', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'rep_email', label: 'Sales rep email', group: 'Sales rep', sample: 'tom@dealership.com', available_for: %w[Lead Contact Account], channels: %w[email] },
      { key: 'rep_phone', label: 'Sales rep phone', group: 'Sales rep', sample: '(303) 555-0100', available_for: %w[Lead Contact Account], channels: %w[email sms] }
    ].freeze

    COMPANY_FIELDS = [
      { key: 'company.name', label: 'Company name', group: 'Company', sample: 'Mountain Home RV Sales', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'company.phone', label: 'Company phone', group: 'Company', sample: '(303) 555-0001', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'company.email', label: 'Company email', group: 'Company', sample: 'info@dealership.com', available_for: %w[Lead Contact Account], channels: %w[email] },
      { key: 'company.website', label: 'Company website', group: 'Company', sample: 'https://dealership.com', available_for: %w[Lead Contact Account], channels: %w[email] }
    ].freeze

    SYSTEM_FIELDS = [
      { key: 'unsubscribe_url', label: 'Unsubscribe link', group: 'System', sample: 'https://app.example.com/u/abc123', available_for: %w[Lead Contact Account], channels: %w[email] },
      { key: 'view_in_browser_url', label: 'View in browser link', group: 'System', sample: 'https://app.example.com/v/abc123', available_for: %w[Lead Contact Account], channels: %w[email] },
      { key: 'public_inventory_url', label: 'Public inventory link', group: 'System', sample: 'https://dealership.com/inventory', available_for: %w[Lead Contact Account], channels: %w[email sms] }
    ].freeze

    ACCOUNT_FIELDS = [
      { key: 'account_name', label: 'Account name', group: 'Account', sample: 'Acme Corp', available_for: %w[Account], channels: %w[email sms] }
    ].freeze

    def self.for_source_type(source_type, channel: nil)
      all = UNIVERSAL_FIELDS + REP_FIELDS + COMPANY_FIELDS + SYSTEM_FIELDS + ACCOUNT_FIELDS
      filtered = all.select { |f| f[:available_for].include?(source_type) }
      filtered = filtered.select { |f| f[:channels].include?(channel) } if channel
      filtered
    end

    def self.grouped_for_source_type(source_type, channel: nil)
      for_source_type(source_type, channel: channel).group_by { |f| f[:group] }
    end
  end
end
