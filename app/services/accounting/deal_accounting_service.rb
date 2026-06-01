# frozen_string_literal: true

module Accounting
  class DealAccountingService
    def initialize(deal)
      @deal = deal
      @company = deal.company
    end

    def calculate_profitability!
      # GP figures come from the single canonical method (Deal#front_gross), which sources
      # cost from the vehicle (live while open, snapshot once closed). We persist only the
      # derived totals used by raw-column readers; front/total gross themselves are always
      # recomputed by the model methods.
      total_gross = @deal.total_gross
      @deal.net_deal_profit = total_gross - (@deal.commission_amount || 0)
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
        # COGS basis = the SAME unified vehicle landed cost GP uses (the close-time
        # snapshot). This ties COGS == GP cost on the GL. Reconditioning posts on its own
        # line below (scope of the tie-out is vehicle cost + recon).
        home_cost = (@deal.vehicle_landed_cost || @deal.home_cost || BigDecimal('0')).to_d

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
            tax_result = post_sales_tax_entries!(user: user)
            { success: true, journal_entry: je, lines_count: lines.count, tax: tax_result }
          else
            raise ActiveRecord::Rollback, "Failed to create journal entry"
          end
        else
          { success: true, message: 'No GL lines to post (missing account configuration)' }
        end
      end
    end

    def post_sales_tax_entries!(user: nil)
      settings = AccountingSettings.for_company(@company)
      return { success: true, skipped: 'sales_tax_disabled', entries: [], total_tax: BigDecimal('0') } unless settings.sales_tax_enabled

      state_code = deal_state_code
      return { success: true, skipped: 'no_state_code', entries: [], total_tax: BigDecimal('0') } if state_code.blank?

      ar_account = settings.default_ar_account
      return { success: true, skipped: 'missing_ar_account', entries: [], total_tax: BigDecimal('0') } unless ar_account

      selling_price = BigDecimal((@deal.try(:selling_price) || @deal.try(:amount) || @deal.try(:total_amount) || 0).to_s)
      return { success: true, skipped: 'no_selling_price', entries: [], total_tax: BigDecimal('0') } if selling_price <= 0

      rates = settings.combined_tax_rate(state_code)
      accounts = settings.tax_accounts
      posting_service = ManualPostingService.new(@company)

      entries = []
      je_ids = []
      total_tax = BigDecimal('0')
      location_id = @deal.try(:location_id)

      [:state, :county, :city].each do |slot|
        rate = rates[slot] || BigDecimal('0')
        account = accounts[slot]
        next if rate.nil? || rate <= 0
        next if account.nil?

        amount = (selling_price * rate / 100).round(2)
        next if amount <= 0

        je = posting_service.post_simple!(
          debit_account: ar_account,
          credit_account: account,
          amount: amount,
          memo: "Sales tax (#{slot.to_s.capitalize}) — #{deal_description}",
          entry_date: deal_close_date,
          source_entity: @deal,
          location_id: location_id,
          department: deal_department,
          contact_id: @deal.try(:contact_id) || @deal.try(:lead_id),
          deal_id: @deal.id,
          vehicle_id: @deal.try(:vehicle_id),
          posted_by: user
        )

        next unless je

        entries << { jurisdiction: slot, rate: rate, amount: amount, journal_entry_id: je.id }
        je_ids << je.id
        total_tax += amount
      end

      @deal.update!(
        delivery_state: state_code,
        state_tax_rate: rates[:state],
        county_tax_rate: rates[:county],
        city_tax_rate: rates[:city],
        total_tax_amount: total_tax,
        tax_posted: entries.any?,
        tax_journal_entry_ids: ((@deal.tax_journal_entry_ids || []) + je_ids).uniq
      )

      { success: true, entries: entries, total_tax: total_tax }
    end

    def profitability_summary
      selling_price = @deal.try(:selling_price) || @deal.try(:amount) || @deal.try(:total_amount) || BigDecimal('0')
      vehicle = @deal.try(:vehicle)
      owner = @deal.try(:owner) || @deal.try(:user)

      # Delegate to the SINGLE canonical method. Front gross sources cost from the vehicle
      # (live while open, snapshot once closed) and excludes pack (a holdback, not a cost).
      # nil when no cost has been entered — surfaced as a flag rather than a guessed margin.
      landed_cost = @deal.landed_cost
      cost_entered = !landed_cost.nil?
      front_gross = @deal.front_gross

      # Exclude the home/vehicle line item from back_gross. It's already counted
      # in selling_price (front side), so summing it again double-counts the
      # entire home as profit. Back-end revenue is only F&I, accessories, fees.
      back_products = (@deal.try(:deal_products) || []).reject { |p| home_line_item?(p) }
      back_gross = back_products.sum { |p| p.try(:price) || p.try(:amount) || p.try(:total) || BigDecimal('0') }

      total_gross = cost_entered ? (front_gross + back_gross) : nil

      commission = @deal.try(:commission_amount) || BigDecimal('0')
      net_profit = total_gross.nil? ? nil : (total_gross - commission)

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
        landed_cost: landed_cost,
        cost_entered: cost_entered,
        cost_flag: cost_entered ? nil : 'cost_not_entered',
        front_gross: front_gross,
        commissionable_front_gross: @deal.commissionable_front_gross,
        back_gross: back_gross,
        total_gross: total_gross,
        commission: commission,
        net_profit: net_profit,
        front_detail: {
          vehicle_cost: @deal.vehicle_landed_cost,
          recon: @deal.reconditioning_cost || 0,
          floor_plan_interest: @deal.floor_plan_interest || 0,
          delivery: @deal.delivery_setup_cost || 0,
          pack: @deal.effective_pack_amount # separate holdback, NOT part of front cost
        },
        back_detail: back_products.map { |p|
          {
            name: p.try(:name) || p.try(:product_name) || p.try(:product_type),
            amount: p.try(:price) || p.try(:amount) || p.try(:total) || 0
          }
        },
        gl_posted: @deal.gl_posted?,
        tax: tax_summary
      }
    end

    def tax_summary
      {
        state_rate: @deal.try(:state_tax_rate),
        county_rate: @deal.try(:county_tax_rate),
        city_rate: @deal.try(:city_tax_rate),
        total_tax: @deal.try(:total_tax_amount) || BigDecimal('0'),
        posted: @deal.try(:tax_posted) || false
      }
    end

    private

    # The home/vehicle is stored as a deal_product line in addition to being
    # represented by deal.selling_price. Identify it so back_gross doesn't
    # double-count it. DealProduct has no category/source_type columns, so we
    # detect it by:
    #   - product_name matching the linked vehicle's "year make model"
    #   - or unit_price equal to the deal's selling_price (custom-line fallback)
    def home_line_item?(product)
      return false unless product

      pname = product.try(:product_name).to_s.strip
      vname = deal_vehicle_name
      return true if vname.present? && pname.casecmp(vname).zero?

      selling = (@deal.try(:selling_price) || @deal.try(:amount) || @deal.try(:total_amount)).to_f
      return false unless selling > 0

      unit = product.try(:unit_price).to_f
      unit > 0 && (unit - selling).abs < 0.01
    end

    def deal_vehicle_name
      v = @deal.try(:vehicle)
      return nil unless v
      [v.try(:year), v.try(:make), v.try(:model)]
        .compact.map(&:to_s).reject(&:empty?).join(' ').strip.presence
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

    def deal_state_code
      raw = @deal.try(:delivery_state).presence ||
            @deal.try(:state).presence ||
            @deal.try(:billing_state).presence ||
            @deal.try(:location)&.try(:state).presence
      raw&.to_s&.strip&.upcase.presence
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
