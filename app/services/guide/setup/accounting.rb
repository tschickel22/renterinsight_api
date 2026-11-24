# frozen_string_literal: true

module Guide
  module Setup
    # How a dealership's books are set up, for the help assistant (E118).
    # Accounting brings the most questions once a dealer keeps its books
    # here, both how-to and bookkeeping, so this reads what those answers
    # depend on: which account each kind of posting uses, what posts by
    # itself, closed periods, the QuickBooks switch, and each bank account's
    # feed and last reconciliation.
    #
    # Guide::SetupAreas has already checked the module is on the plan and the
    # person can read accounting.
    class Accounting
      DEFAULT_ACCOUNTS = {
        accounts_receivable: :default_ar_account_id, accounts_payable: :default_ap_account_id,
        sales_revenue: :default_sales_revenue_account_id, cost_of_sales: :default_cogs_account_id,
        sales_tax_payable: :default_sales_tax_payable_account_id, bank: :default_bank_account_id,
        home_inventory: :default_vehicle_inventory_account_id, parts_inventory: :default_parts_inventory_account_id,
        customer_deposits: :customer_deposits_account_id, retained_earnings: :retained_earnings_account_id
      }.freeze

      AUTO_POST = {
        invoices: :auto_post_invoices, payments: :auto_post_payments, bills: :auto_post_purchases,
        purchase_orders: :auto_post_purchase_orders, parts_used: :auto_post_parts_usage, deals: :auto_post_deals
      }.freeze

      def initialize(ctx)
        @ctx = ctx
        @company = ctx.company
      end

      def to_h
        settings = AccountingSettings.for_company(@company)
        return { set_up: false, note: 'Accounting has not been set up yet (no accounting settings saved).' } unless settings

        {
          method: settings.accounting_method,
          fiscal_year_starts: settings.fiscal_year_start_month && Date::MONTHNAMES[settings.fiscal_year_start_month.to_i],
          posts_to_these_accounts: fact { default_accounts(settings) },
          posts_by_itself: fact { AUTO_POST.transform_values { |col| settings.try(col) ? 'yes' : 'no' } },
          sales_tax: fact { sales_tax(settings) },
          floor_plan: fact { floor_plan(settings) },
          closed_periods: fact { closed_periods(settings) },
          chart_of_accounts: fact { @company.chart_of_accounts.where(is_active: true).count },
          tax_codes: fact { @company.tax_codes.where(is_active: true).order(:position).limit(15).map { |t| { name: t.name, rate: t.rate&.to_f } } },
          quickbooks: fact { quickbooks },
          quickbooks_switch: fact { quickbooks_switch },
          bank_accounts: fact { bank_accounts }
        }.compact
      end

      private

      # A savepoint, so one failed query never spoils the ones after it.

      def fact(&block)

        ActiveRecord::Base.transaction(requires_new: true, &block)
      rescue StandardError => e
        Rails.logger.info("[Guide::Setup::Accounting] skipped a fact: #{e.class} #{e.message}")
        nil
      end

      def account_label(id)
        return 'not set' if id.blank?

        @accounts ||= @company.chart_of_accounts.pluck(:id, :account_number, :name).to_h { |i, n, name| [i, "#{n} #{name}".strip] }
        @accounts[id] || "account #{id}"
      end

      def default_accounts(settings)
        DEFAULT_ACCOUNTS.transform_values { |col| account_label(settings.try(col)) }
      end

      def sales_tax(settings)
        {
          on: settings.sales_tax_enabled,
          default_rates_percent: { state: settings.default_state_tax_rate&.to_f, county: settings.default_county_tax_rate&.to_f,
                                   city: settings.default_city_tax_rate&.to_f }.compact,
          states_with_their_own_rates: (settings.tax_rates_by_state || {}).keys.first(20)
        }.compact
      end

      def floor_plan(settings)
        return 'not tracked' unless settings.floor_plan_tracking_enabled

        { tracked: true, default_rate_percent: settings.default_floor_plan_rate&.to_f, default_lender: settings.default_floor_plan_lender }.compact
      end

      def closed_periods(settings)
        closed = @company.fiscal_periods.where(status: 'closed').order(end_date: :desc)
        { last_closed_through: closed.first&.end_date&.iso8601 || 'none closed',
          closing_locks_the_period: settings.lock_period_on_close ? 'yes' : 'no' }
      end

      def quickbooks
        conn = QuickbooksConnection.where(company_id: @company.id).order(updated_at: :desc).first
        return 'not connected' unless conn

        { status: conn.connected? ? 'connected' : conn.status, company: conn.company_name, sync_on: conn.sync_enabled,
          mode: conn.sync_mode, last_sync: conn.last_sync_at&.iso8601, error: conn.error_message.presence&.first(200) }.compact
      end

      def quickbooks_switch
        run = @company.accounting_imports.migrations.order(created_at: :desc).first
        return 'not started' unless run

        { status: run.status, cutover_date: run.cutover_date&.iso8601, started: run.started_at&.to_date&.iso8601,
          imported: run.total_imported, skipped: run.total_skipped, errors: run.total_errors }.compact
      end

      def bank_accounts
        accounts = @company.bank_accounts.where(is_deleted: [false, nil], is_active: true).order(:id).limit(12)
        last_recs = @company.bank_reconciliations.where(bank_account_id: accounts.map(&:id), status: 'completed')
                            .group(:bank_account_id).maximum(:statement_date)
        accounts.map do |b|
          {
            name: [b.institution_name || b.bank_name, b.display_last_four || b.account_mask].compact.join(' ending '),
            purpose: b.account_purpose, books_account: account_label(b.chart_of_account_id),
            bank_feed: b.stripe_fc_account_id.present? ? (b.stripe_fc_status || 'connected') : 'not connected',
            feed_last_synced: b.stripe_fc_last_synced_at&.iso8601,
            last_reconciled_through: last_recs[b.id]&.iso8601 || 'never'
          }.compact
        end
      end
    end
  end
end
