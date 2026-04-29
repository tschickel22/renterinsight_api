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

    DEAL_FIELDS = [
      { key: 'deal.name', label: 'Deal name', group: 'Deal', sample: '2024 Outback purchase', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.stage', label: 'Deal stage', group: 'Deal', sample: 'negotiation', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.value', label: 'Deal value', group: 'Deal', sample: '45000', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.selling_price', label: 'Deal selling price', group: 'Deal', sample: '42500', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.probability', label: 'Deal probability', group: 'Deal', sample: '75', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.expected_close_date', label: 'Deal expected close date', group: 'Deal', sample: '2026-05-15', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.deal_number', label: 'Deal number', group: 'Deal', sample: 'D-000123', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.owner_name', label: 'Deal owner name', group: 'Deal', sample: 'Tom Schickel', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.owner_email', label: 'Deal owner email', group: 'Deal', sample: 'tom@dealership.com', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.customer_name', label: 'Deal customer name', group: 'Deal', sample: 'Sarah Johnson', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'deal.vehicle_description', label: 'Deal vehicle description', group: 'Deal', sample: '2024 Forest River Cherokee', available_for: %w[Lead Contact Account], channels: %w[email sms] }
    ].freeze

    CONTACT_FIELDS = [
      { key: 'contact.first_name', label: 'Contact first name', group: 'Contact', sample: 'Sarah', available_for: %w[Lead Account], channels: %w[email sms] },
      { key: 'contact.last_name', label: 'Contact last name', group: 'Contact', sample: 'Johnson', available_for: %w[Lead Account], channels: %w[email sms] },
      { key: 'contact.full_name', label: 'Contact full name', group: 'Contact', sample: 'Sarah Johnson', available_for: %w[Lead Account], channels: %w[email sms] },
      { key: 'contact.email', label: 'Contact email', group: 'Contact', sample: 'sarah@example.com', available_for: %w[Lead Account], channels: %w[email sms] },
      { key: 'contact.phone', label: 'Contact phone', group: 'Contact', sample: '(303) 555-0123', available_for: %w[Lead Account], channels: %w[email sms] },
      { key: 'contact.title', label: 'Contact title', group: 'Contact', sample: 'Operations Manager', available_for: %w[Lead Account], channels: %w[email sms] },
      { key: 'contact.company_name', label: 'Contact company name', group: 'Contact', sample: 'Acme Corp', available_for: %w[Lead Account], channels: %w[email sms] }
    ].freeze

    ACCOUNT_FIELDS = [
      { key: 'account.name', label: 'Account name', group: 'Account', sample: 'Acme Corp', available_for: %w[Lead Contact], channels: %w[email sms] },
      { key: 'account.email', label: 'Account email', group: 'Account', sample: 'info@acme.com', available_for: %w[Lead Contact], channels: %w[email sms] },
      { key: 'account.phone', label: 'Account phone', group: 'Account', sample: '(303) 555-0200', available_for: %w[Lead Contact], channels: %w[email sms] },
      { key: 'account.website', label: 'Account website', group: 'Account', sample: 'https://acme.com', available_for: %w[Lead Contact], channels: %w[email sms] },
      { key: 'account.industry', label: 'Account industry', group: 'Account', sample: 'Manufacturing', available_for: %w[Lead Contact], channels: %w[email sms] },
      { key: 'account.account_type', label: 'Account type', group: 'Account', sample: 'customer', available_for: %w[Lead Contact], channels: %w[email sms] }
    ].freeze

    VEHICLE_FIELDS = [
      { key: 'vehicle.year', label: 'Vehicle year', group: 'Vehicle', sample: '2024', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'vehicle.make', label: 'Vehicle make', group: 'Vehicle', sample: 'Forest River', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'vehicle.model', label: 'Vehicle model', group: 'Vehicle', sample: 'Cherokee', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'vehicle.description', label: 'Vehicle description', group: 'Vehicle', sample: '2024 Forest River Cherokee', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'vehicle.serial_number', label: 'Vehicle serial number', group: 'Vehicle', sample: 'SN12345', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'vehicle.stock_number', label: 'Vehicle stock number', group: 'Vehicle', sample: 'STK-001', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'vehicle.sale_price', label: 'Vehicle sale price', group: 'Vehicle', sample: '42500', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'vehicle.status', label: 'Vehicle status', group: 'Vehicle', sample: 'available', available_for: %w[Lead Contact Account], channels: %w[email sms] }
    ].freeze

    SERVICE_TICKET_FIELDS = [
      { key: 'service_ticket.ticket_number', label: 'Service ticket number', group: 'Service Ticket', sample: 'ST-000123', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'service_ticket.title', label: 'Service ticket title', group: 'Service Ticket', sample: 'Slide-out repair', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'service_ticket.status', label: 'Service ticket status', group: 'Service Ticket', sample: 'open', available_for: %w[Lead Contact Account], channels: %w[email sms] },
      { key: 'service_ticket.priority', label: 'Service ticket priority', group: 'Service Ticket', sample: 'medium', available_for: %w[Lead Contact Account], channels: %w[email sms] }
    ].freeze

    def self.for_source_type(source_type, channel: nil)
      all = UNIVERSAL_FIELDS + REP_FIELDS + COMPANY_FIELDS + SYSTEM_FIELDS +
            DEAL_FIELDS + CONTACT_FIELDS + ACCOUNT_FIELDS + VEHICLE_FIELDS + SERVICE_TICKET_FIELDS
      filtered = all.select { |f| f[:available_for].include?(source_type) }
      filtered = filtered.select { |f| f[:channels].include?(channel) } if channel
      filtered
    end

    def self.grouped_for_source_type(source_type, channel: nil)
      for_source_type(source_type, channel: channel).group_by { |f| f[:group] }
    end
  end
end
