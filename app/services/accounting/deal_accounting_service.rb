# frozen_string_literal: true

module Accounting
  class DealAccountingService
    def initialize(deal)
      @deal = deal
      @company = deal.company
    end

    def calculate_profitability!
      calculate_front_gross!
      calculate_back_gross!

      @deal.total_gross = (@deal.front_gross || 0) + (@deal.back_gross || 0)
      @deal.net_deal_profit = @deal.total_gross - (@deal.commission_amount || 0)
      @deal.save!

      profitability_summary
    end

    def post_closing_entries!(user: nil)
      return { error: 'Deal is not closed/won' } unless deal_is_closed?
      return { error: 'Already posted to GL' } if @deal.gl_posted?

      settings = AccountingSettings.for_company(@company)
      posting_service = ManualPostingService.new(@company)
      ar_account = settings.default_ar_account

      ActiveRecord::Base.transaction do
        lines = []
        deal_location_id = @deal.try(:location_id)

        selling_price = @deal.try(:selling_price) || @deal.try(:amount) || @deal.try(:total_amount) || BigDecimal('0')
        home_cost = @deal.home_cost || BigDecimal('0')

        if selling_price > 0
          revenue_account = AccountLinkResolver.resolve(company: @company, entity: @deal, purpose: 'revenue') ||
                            settings.default_sales_revenue_account

          if revenue_account && ar_account
            lines << { chart_of_account_id: ar_account.id, debit_amount: selling_price, credit_amount: 0,
                       memo: "Deal revenue — #{deal_description}", location_id: deal_location_id,
                       department: deal_department, deal_id: @deal.id,
                       vehicle_id: @deal.try(:vehicle_id), contact_id: @deal.try(:contact_id) || @deal.try(:lead_id) }
            lines << { chart_of_account_id: revenue_account.id, debit_amount: 0, credit_amount: selling_price,
                       memo: "Deal revenue — #{deal_description}", location_id: deal_location_id,
                       department: deal_department, deal_id: @deal.id,
                       vehicle_id: @deal.try(:vehicle_id) }
          end
        end

        if home_cost > 0
          cogs_account = AccountLinkResolver.resolve(company: @company, entity: @deal, purpose: 'cogs') ||
                         settings.default_cogs_account
          inventory_account = @company.chart_of_accounts.find_by(account_number: '1210')

          if cogs_account && inventory_account
            lines << { chart_of_account_id: cogs_account.id, debit_amount: home_cost, credit_amount: 0,
                       memo: "COGS — #{deal_description}", location_id: deal_location_id,
                       department: deal_department, deal_id: @deal.id,
                       vehicle_id: @deal.try(:vehicle_id) }
            lines << { chart_of_account_id: inventory_account.id, debit_amount: 0, credit_amount: home_cost,
                       memo: "Inventory relief — #{deal_description}", location_id: deal_location_id,
                       department: deal_department, deal_id: @deal.id,
                       vehicle_id: @deal.try(:vehicle_id) }
          end
        end

        recon_cost = @deal.reconditioning_cost || BigDecimal('0')
        if recon_cost > 0
          recon_cogs = @company.chart_of_accounts.find_by(account_number: '5110')
          recon_wip = @company.chart_of_accounts.find_by(account_number: '1240')
          if recon_cogs && recon_wip
            lines << { chart_of_account_id: recon_cogs.id, debit_amount: recon_cost, credit_amount: 0,
                       memo: "Reconditioning — #{deal_description}", location_id: deal_location_id,
                       department: deal_department, deal_id: @deal.id }
            lines << { chart_of_account_id: recon_wip.id, debit_amount: 0, credit_amount: recon_cost,
                       memo: "Reconditioning — #{deal_description}", location_id: deal_location_id,
                       department: deal_department, deal_id: @deal.id }
          end
        end

        fp_amount = @deal.try(:floor_plan_amount) || BigDecimal('0')
        if fp_amount > 0
          fp_liability = @company.chart_of_accounts.find_by(account_number: '2110')
          bank_account = @company.chart_of_accounts.where(sub_type: 'bank', is_active: true).order(:account_number).first
          if fp_liability && bank_account
            lines << { chart_of_account_id: fp_liability.id, debit_amount: fp_amount, credit_amount: 0,
                       memo: "Floor plan payoff — #{deal_description}", location_id: deal_location_id,
                       deal_id: @deal.id, vehicle_id: @deal.try(:vehicle_id) }
            lines << { chart_of_account_id: bank_account.id, debit_amount: 0, credit_amount: fp_amount,
                       memo: "Floor plan payoff — #{deal_description}", location_id: deal_location_id,
                       deal_id: @deal.id }
          end
        end

        fi_products = @deal.try(:deal_products) || []
        fi_products.each do |product|
          product_revenue = product.try(:price) || product.try(:amount) || product.try(:total) || BigDecimal('0')
          next if product_revenue <= 0

          fi_revenue_account = resolve_fi_account(product) ||
                               @company.chart_of_accounts.find_by(account_number: '4110')

          if fi_revenue_account && ar_account
            lines << { chart_of_account_id: ar_account.id, debit_amount: product_revenue, credit_amount: 0,
                       memo: "F&I: #{product.try(:name) || product.try(:product_name) || product.try(:product_type)} — #{deal_description}",
                       location_id: deal_location_id, department: 'fi', deal_id: @deal.id }
            lines << { chart_of_account_id: fi_revenue_account.id, debit_amount: 0, credit_amount: product_revenue,
                       memo: "F&I: #{product.try(:name) || product.try(:product_name) || product.try(:product_type)} — #{deal_description}",
                       location_id: deal_location_id, department: 'fi', deal_id: @deal.id }
          end
        end

        commission = @deal.commission_amount || BigDecimal('0')
        if commission > 0
          commission_exp = @company.chart_of_accounts.find_by(account_number: '6010')
          accrued_comp = @company.chart_of_accounts.find_by(account_number: '2020')
          if commission_exp && accrued_comp
            lines << { chart_of_account_id: commission_exp.id, debit_amount: commission, credit_amount: 0,
                       memo: "Commission — #{deal_description}", location_id: deal_location_id,
                       department: deal_department, deal_id: @deal.id }
            lines << { chart_of_account_id: accrued_comp.id, debit_amount: 0, credit_amount: commission,
                       memo: "Commission — #{deal_description}", location_id: deal_location_id,
                       department: deal_department, deal_id: @deal.id }
          end
        end

        if lines.any?
          je = posting_service.post_complex!(
            lines: lines,
            memo: "Deal closing — #{deal_description}",
            entry_date: deal_close_date,
            source_entity: @deal,
            posted_by: user
          )

          if je
            @deal.update!(gl_posted: true, gl_posted_at: Time.current, gl_journal_entry_id: je.id)
            { success: true, journal_entry: je, lines_count: lines.count }
          else
            raise ActiveRecord::Rollback, "Failed to create journal entry"
          end
        else
          { success: true, message: 'No GL lines to post (missing account configuration)' }
        end
      end
    end

    def profitability_summary
      selling_price = @deal.try(:selling_price) || @deal.try(:amount) || @deal.try(:total_amount) || BigDecimal('0')
      vehicle = @deal.try(:vehicle)
      owner = @deal.try(:owner) || @deal.try(:user)

      # Calculate front gross on-the-fly if not stored
      front_gross = @deal.try(:front_gross)
      if front_gross.nil? || front_gross.zero?
        front_gross = selling_price - total_front_costs
      end

      back_gross = @deal.try(:back_gross)
      if back_gross.nil? || back_gross.zero?
        products = @deal.try(:deal_products) || []
        back_gross = products.sum { |p| p.try(:price) || p.try(:amount) || p.try(:total) || BigDecimal('0') }
      end

      total_gross = @deal.try(:total_gross)
      if total_gross.nil? || total_gross.zero?
        total_gross = front_gross + back_gross
      end

      commission = @deal.try(:commission_amount) || BigDecimal('0')
      net_profit = @deal.try(:net_deal_profit)
      if net_profit.nil? || net_profit.zero?
        net_profit = total_gross - commission
      end

      {
        deal_id: @deal.id,
        deal_title: @deal.try(:title) || @deal.try(:name),
        deal_number: @deal.try(:deal_number),
        vehicle: vehicle ? {
          id: vehicle.id,
          year: vehicle.try(:year),
          make: vehicle.try(:make),
          model: vehicle.try(:model),
          vin: vehicle.try(:vin),
          stock_number: vehicle.try(:stock_number)
        } : nil,
        salesperson: owner ? {
          id: owner.id,
          name: [owner.try(:first_name), owner.try(:last_name)].compact.join(' ').presence || owner.try(:email)
        } : nil,
        selling_price: selling_price,
        front_gross: front_gross,
        back_gross: back_gross,
        total_gross: total_gross,
        commission: commission,
        net_profit: net_profit,
        front_detail: {
          home_cost: @deal.home_cost || 0,
          recon: @deal.reconditioning_cost || 0,
          floor_plan_interest: @deal.floor_plan_interest || 0,
          delivery: @deal.delivery_setup_cost || 0,
          pack: @deal.pack_amount || 0
        },
        back_detail: (@deal.try(:deal_products) || []).map { |p|
          {
            name: p.try(:name) || p.try(:product_name) || p.try(:product_type),
            amount: p.try(:price) || p.try(:amount) || p.try(:total) || 0
          }
        },
        gl_posted: @deal.gl_posted?
      }
    end

    private

    def calculate_front_gross!
      selling_price = @deal.try(:selling_price) || @deal.try(:amount) || @deal.try(:total_amount) || BigDecimal('0')
      @deal.front_gross = selling_price - total_front_costs
    end

    def calculate_back_gross!
      products = @deal.try(:deal_products) || []
      @deal.back_gross = products.sum { |p|
        p.try(:price) || p.try(:amount) || p.try(:total) || BigDecimal('0')
      }
    end

    def total_front_costs
      (@deal.home_cost || 0) +
        (@deal.reconditioning_cost || 0) +
        (@deal.floor_plan_interest || 0) +
        (@deal.delivery_setup_cost || 0) +
        (@deal.pack_amount || 0)
    end

    def deal_is_closed?
      closed_statuses = %w[closed_won won closed completed]
      @deal.try(:status)&.downcase&.in?(closed_statuses) ||
        @deal.try(:stage)&.downcase&.in?(closed_statuses)
    end

    def deal_close_date
      (@deal.try(:closed_at) ||
       @deal.try(:won_at) ||
       @deal.try(:actual_close_date))&.to_date || Date.current
    end

    def deal_department
      if @deal.try(:deal_type)&.downcase&.include?('used')
        'used_sales'
      else
        'new_sales'
      end
    end

    def deal_description
      vehicle = @deal.try(:vehicle)
      title = @deal.try(:title) || @deal.try(:name)
      if vehicle
        "#{vehicle.try(:year)} #{vehicle.try(:make)} #{vehicle.try(:model)} — #{title}"
      else
        title || "Deal ##{@deal.id}"
      end
    end

    def resolve_fi_account(product)
      product_type = product.try(:product_type)&.downcase || ''
      case product_type
      when /warranty/, /extended/ then @company.chart_of_accounts.find_by(account_number: '4110')
      when /insurance/ then @company.chart_of_accounts.find_by(account_number: '4120')
      when /gap/ then @company.chart_of_accounts.find_by(account_number: '4130')
      when /finance/, /reserve/, /participation/ then @company.chart_of_accounts.find_by(account_number: '4140')
      else @company.chart_of_accounts.find_by(account_number: '4110')
      end
    end
  end
end
