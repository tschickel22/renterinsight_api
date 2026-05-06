# frozen_string_literal: true

require 'net/http'
require 'json'

module Accounting
  module Adapters
    class FreshbooksAdapter
      attr_reader :source_name

      API_BASE = 'https://api.freshbooks.com/accounting/account'

      def initialize(company, config)
        @company = company
        @config = config
        @source_name = 'Freshbooks'
        @access_token = config['access_token']
        @account_id   = config['account_id']
      end

      def count_accounts
        fetch_with_count('/expenses/categories')
      end

      def count_contacts
        fetch_with_count('/users/clients')
      end

      def count_vendors
        0
      end

      def count_open_invoices
        fetch_with_count('/invoices/invoices', { status: 'unpaid' })
      end

      def fetch_accounts
        Rails.logger.info("[FreshbooksAdapter] fetch_accounts called — implement with real API")
        []
      end

      def fetch_contacts
        response = api_get("/users/clients")
        clients = response.dig('response', 'result', 'clients') || []

        clients.map do |client|
          {
            name: "#{client['fname']} #{client['lname']}".strip,
            first_name: client['fname'],
            last_name: client['lname'],
            email: client['email'],
            phone: client['mob_phone'] || client['bus_phone'],
            company_name: client['organization'],
            street: client['p_street'],
            city: client['p_city'],
            state: client['p_province'],
            zip: client['p_code']
          }
        end
      rescue => e
        Rails.logger.error("[FreshbooksAdapter] fetch_contacts failed: #{e.message}")
        []
      end

      def fetch_vendors
        []
      end

      def fetch_account_balances(_cutover_date)
        []
      end

      def fetch_open_invoices
        response = api_get("/invoices/invoices", { status: 'unpaid', per_page: 100 })
        invoices = response.dig('response', 'result', 'invoices') || []

        invoices.map do |inv|
          {
            invoice_number: inv['invoice_number'],
            date: inv['create_date'] ? Date.parse(inv['create_date']) : nil,
            due_date: inv['due_date'] ? Date.parse(inv['due_date']) : nil,
            customer_name: inv['current_organization'] || "Client #{inv['customerid']}",
            amount: inv.dig('amount', 'amount')&.to_d,
            balance: inv.dig('outstanding', 'amount')&.to_d,
            total: inv.dig('amount', 'amount')&.to_d
          }
        end
      rescue => e
        Rails.logger.error("[FreshbooksAdapter] fetch_open_invoices failed: #{e.message}")
        []
      end

      private

      def api_get(path, params = {})
        uri = URI("#{API_BASE}/#{@account_id}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Get.new(uri)
        request['Authorization'] = "Bearer #{@access_token}"
        request['Api-Version']   = 'alpha'
        request['Content-Type']  = 'application/json'

        response = http.request(request)
        JSON.parse(response.body)
      end

      def fetch_with_count(path, params = {})
        response = api_get(path, params.merge(per_page: 1))
        response.dig('response', 'result', 'total') || 0
      rescue StandardError
        0
      end
    end
  end
end
