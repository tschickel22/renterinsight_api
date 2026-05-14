# frozen_string_literal: true

module Accounting
  module Adapters
    class QuickbooksDesktopAdapter
      attr_reader :source_name

      def initialize(company, config)
        @company = company
        @config = config
        @source_name = 'QuickBooks Desktop'

        if config['file_data'].present?
          parse_iif(config['file_data'])
        elsif config['parsed_data'].present?
          @accounts     = config['parsed_data']['accounts'] || []
          @customers    = config['parsed_data']['customers'] || []
          @vendors      = config['parsed_data']['vendors'] || []
          @transactions = config['parsed_data']['transactions'] || []
        else
          @accounts = []; @customers = []; @vendors = []; @transactions = []
        end
      end

      def count_accounts;  @accounts.count;  end
      def count_contacts;  @customers.count; end
      def count_vendors;   @vendors.count;   end
      def count_open_invoices; 0; end

      def fetch_accounts
        @accounts.map do |acct|
          {
            account_number: acct[:accnum].presence,
            name: acct[:name],
            account_type: map_iif_type(acct[:accnttype]),
            sub_type: map_iif_sub_type(acct[:accnttype]),
            description: acct[:desc],
            is_header: acct[:accnttype]&.upcase == 'OCCASSET',
            is_active: acct[:hidden]&.upcase != 'Y',
            balance: acct[:balance].present? ? BigDecimal(acct[:balance].to_s.gsub(/[$,]/, '')) : nil
          }
        end
      end

      def fetch_contacts
        @customers.map do |cust|
          street = cust[:baddr1] || cust[:addr1]
          city_state_zip = cust[:baddr2] || cust[:addr2] || ''
          city, state_zip = parse_city_state_zip(city_state_zip)
          state, zip = parse_state_zip(state_zip)

          {
            name: cust[:name],
            first_name: cust[:firstname] || cust[:name]&.split(' ')&.first,
            last_name: cust[:lastname] || cust[:name]&.split(' ', 2)&.last,
            email: cust[:email],
            phone: cust[:phone1] || cust[:phone],
            company_name: cust[:companyname] || cust[:company],
            street: street,
            city: city || cust[:baddr3] || cust[:city],
            state: state || cust[:state],
            zip: zip || cust[:zip]
          }
        end
      end

      def fetch_vendors
        @vendors.map do |v|
          street = v[:addr1] || v[:vaddr1]
          city_state_zip = v[:addr2] || v[:vaddr2] || ''
          city, state_zip = parse_city_state_zip(city_state_zip)
          state, zip = parse_state_zip(state_zip)

          {
            name: v[:name],
            email: v[:email],
            phone: v[:phone1] || v[:phone],
            street: street,
            city: city || v[:city],
            state: state || v[:state],
            zip: zip || v[:zip]
          }
        end
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
        []
      end

      private

      def parse_iif(file_content)
        @accounts = []; @customers = []; @vendors = []; @transactions = []
        headers = []

        file_content.each_line do |line|
          line = line.strip.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
          next if line.blank?

          fields = line.split("\t")

          if fields[0]&.start_with?('!')
            headers = fields.map { |f| f.sub('!', '').downcase.strip.to_sym }
            next
          end

          row_type = fields[0]&.upcase
          row_data = {}
          headers.each_with_index do |header, i|
            row_data[header] = fields[i]&.strip if i < fields.length
          end

          case row_type
          when 'ACCNT' then @accounts << row_data
          when 'CUST'  then @customers << row_data
          when 'VEND'  then @vendors << row_data
          when 'TRNS', 'SPL' then @transactions << row_data.merge(row_type: row_type)
          end
        end

        Rails.logger.info("[IIF Parser] Parsed: #{@accounts.count} accounts, #{@customers.count} customers, #{@vendors.count} vendors")
      end

      def parse_city_state_zip(str)
        return [nil, nil] if str.blank?
        parts = str.split(',', 2).map(&:strip)
        [parts[0], parts[1]]
      rescue StandardError
        [nil, nil]
      end

      def parse_state_zip(str)
        return [nil, nil] if str.blank?
        parts = str.strip.split(/\s+/, 2)
        [parts[0], parts[1]]
      rescue StandardError
        [nil, nil]
      end

      def map_iif_type(iif_type)
        case iif_type&.upcase
        when 'BANK', 'OASSET', 'FIXASSET', 'AR' then 'asset'
        when 'CCARD', 'OCLIAB', 'LTLIAB', 'AP' then 'liability'
        when 'EQUITY' then 'equity'
        when 'INC', 'OTHERINC' then 'revenue'
        when 'EXP', 'OTHEREXP', 'COGS' then 'expense'
        else 'expense'
        end
      end

      def map_iif_sub_type(iif_type)
        case iif_type&.upcase
        when 'BANK' then 'bank'
        when 'AR' then 'accounts_receivable'
        when 'AP' then 'accounts_payable'
        when 'COGS' then 'cost_of_goods_sold'
        when 'FIXASSET' then 'fixed_asset'
        when 'CCARD' then 'current_liability'
        when 'LTLIAB' then 'long_term_liability'
        when 'EQUITY' then 'owners_equity'
        when 'INC' then 'sales_revenue'
        when 'EXP' then 'operating_expense'
        end
      end
    end
  end
end
