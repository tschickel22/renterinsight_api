# frozen_string_literal: true

module Accounting
  module Adapters
    class CsvAdapter
      attr_reader :source_name

      def initialize(company, config)
        @company = company
        @config = config
        @source_name = 'CSV Import'
        @data = config['data'] || {}
        @mappings = config['mappings'] || {}
      end

      def count_accounts
        (@data['accounts'] || []).count
      end

      def count_contacts
        (@data['contacts'] || []).count
      end

      def count_vendors
        (@data['vendors'] || []).count
      end

      def count_open_invoices
        (@data['invoices'] || []).count
      end

      def fetch_accounts
        rows = @data['accounts'] || []
        mapping = @mappings['accounts'] || {}

        rows.map do |row|
          {
            account_number: extract(row, mapping, 'account_number'),
            name: extract(row, mapping, 'name'),
            account_type: normalize_account_type(extract(row, mapping, 'account_type')),
            sub_type: extract(row, mapping, 'sub_type'),
            description: extract(row, mapping, 'description'),
            is_header: extract(row, mapping, 'is_header')&.to_s&.downcase&.in?(%w[true yes 1 header]),
            is_active: extract(row, mapping, 'is_active')&.to_s&.downcase&.in?(%w[true yes 1 active]) != false,
            balance: parse_decimal(extract(row, mapping, 'balance'))
          }
        end.reject { |a| a[:name].blank? }
      end

      def fetch_contacts
        rows = @data['contacts'] || []
        mapping = @mappings['contacts'] || {}

        rows.map do |row|
          name = extract(row, mapping, 'name') || ''
          parts = name.split(' ', 2)
          {
            name: name,
            first_name: extract(row, mapping, 'first_name') || parts[0],
            last_name: extract(row, mapping, 'last_name') || parts[1],
            email: extract(row, mapping, 'email'),
            phone: extract(row, mapping, 'phone'),
            company_name: extract(row, mapping, 'company_name') || extract(row, mapping, 'company'),
            street: extract(row, mapping, 'street') || extract(row, mapping, 'address'),
            city: extract(row, mapping, 'city'),
            state: extract(row, mapping, 'state'),
            zip: extract(row, mapping, 'zip') || extract(row, mapping, 'postal_code')
          }
        end.reject { |c| c[:name].blank? && c[:email].blank? }
      end

      def fetch_vendors
        rows = @data['vendors'] || []
        mapping = @mappings['vendors'] || {}

        rows.map do |row|
          {
            name: extract(row, mapping, 'name'),
            email: extract(row, mapping, 'email'),
            phone: extract(row, mapping, 'phone'),
            street: extract(row, mapping, 'street') || extract(row, mapping, 'address'),
            city: extract(row, mapping, 'city'),
            state: extract(row, mapping, 'state'),
            zip: extract(row, mapping, 'zip')
          }
        end.reject { |v| v[:name].blank? }
      end

      def fetch_account_balances(_cutover_date)
        fetch_accounts.filter_map do |acct|
          next if acct[:balance].nil? || acct[:balance].zero?
          {
            account_number: acct[:account_number],
            account_name: acct[:name],
            balance: acct[:balance]
          }
        end
      end

      def fetch_open_invoices
        rows = @data['invoices'] || []
        mapping = @mappings['invoices'] || {}

        rows.map do |row|
          {
            invoice_number: extract(row, mapping, 'invoice_number') || extract(row, mapping, 'number'),
            date: parse_date(extract(row, mapping, 'date')),
            due_date: parse_date(extract(row, mapping, 'due_date')),
            customer_name: extract(row, mapping, 'customer') || extract(row, mapping, 'customer_name'),
            amount: parse_decimal(extract(row, mapping, 'amount') || extract(row, mapping, 'total')),
            balance: parse_decimal(extract(row, mapping, 'balance') || extract(row, mapping, 'amount_due')),
            total: parse_decimal(extract(row, mapping, 'total') || extract(row, mapping, 'amount'))
          }
        end.reject { |i| i[:amount].nil? || i[:amount].zero? }
      end

      private

      def extract(row, mapping, field)
        key = mapping[field]
        return nil unless key.present?

        if key.is_a?(Integer)
          row[key]
        elsif row.is_a?(Hash)
          row[key] || row[key.to_sym]
        elsif row.is_a?(Array)
          row[key.to_i]
        end
      end

      def parse_decimal(value)
        return nil if value.blank?
        BigDecimal(value.to_s.gsub(/[$,\s]/, ''))
      rescue ArgumentError, TypeError
        nil
      end

      def parse_date(value)
        return nil if value.blank?
        Date.parse(value.to_s)
      rescue Date::Error
        nil
      end

      def normalize_account_type(type)
        return 'expense' if type.blank?
        case type.to_s.downcase.strip
        when /asset/, /bank/, /receivable/, /inventory/ then 'asset'
        when /liabilit/, /payable/ then 'liability'
        when /equity/, /capital/, /retained/ then 'equity'
        when /income/, /revenue/, /sales/ then 'revenue'
        when /expense/, /cost/, /cogs/ then 'expense'
        else 'expense'
        end
      end
    end
  end
end
