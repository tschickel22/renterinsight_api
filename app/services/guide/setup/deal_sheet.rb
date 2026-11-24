# frozen_string_literal: true

module Guide
  module Setup
    # How a dealership set up its deals and Deal Sheet, for the help assistant
    # (E118 step 3): pack, doc fee, dealer pack and freight terms, packages and
    # fees, sales tax, deal stages and lenders. The deal sheet was asked about
    # 7 times in the month before (costs and freight, tax disappearing, lines
    # that could not be removed).
    class DealSheet
      def initialize(ctx)
        @ctx = ctx
        @company = ctx.company
      end

      def to_h
        {
          deal_stages: fact { stages },
          pack: fact { pack },
          price_book_terms: fact { terms },
          packages: fact { packages },
          fees: fact { fees },
          sales_tax: fact { sales_tax },
          lenders: fact { @company.lenders.where(is_deleted: [false, nil], active: true).order(:name).limit(20).pluck(:name).presence }
        }.compact
      end

      private

      # A savepoint, so one failed query never spoils the ones after it.
      def fact(&block)
        ActiveRecord::Base.transaction(requires_new: true, &block)
      rescue StandardError => e
        Rails.logger.info("[Guide::Setup::DealSheet] skipped a fact: #{e.class} #{e.message}")
        nil
      end

      def money(value)
        value.nil? ? nil : value.to_d.round(2).to_f
      end

      def stages
        @company.pipeline_stages.map { |s| s['label'] || s[:label] || s['name'] || s[:name] || s['key'] || s[:key] }.compact
      end

      # Pack comes off before commissionable gross: the deal's own pack, else
      # its location's default, else the company's (Deal#effective_pack_amount).
      def pack
        by_location = @company.locations.where(active: true, is_deleted: false).where.not(default_pack_amount: nil)
                              .pluck(:name, :default_pack_amount).to_h { |n, a| [n, money(a)] }
        { company_default: money(@company.try(:default_pack_amount)) || 0.0, by_location: by_location.presence,
          order: "A deal's own pack, else its location's default, else the company default." }.compact
      end

      # The company-wide price book terms, and each builder's where it differs.
      def terms
        rows = @company.dealer_catalog_terms.to_a
        return 'No price book terms are set.' if rows.empty?

        names = Manufacturer.where(id: rows.map(&:manufacturer_id).compact).pluck(:id, :name).to_h
        rows.sort_by { |t| [t.manufacturer_id ? 1 : 0, names[t.manufacturer_id].to_s] }.first(12).map do |t|
          { builder: t.manufacturer_id ? names[t.manufacturer_id] || "builder #{t.manufacturer_id}" : 'all builders (company-wide)',
            doc_fee: money(t.doc_fee), dealer_pack: money(t.dealer_pack),
            freight: { per_mile: money(t.freight_per_mile), flat: money(t.freight_flat), minimum: money(t.freight_minimum),
                       markup_percent: t.freight_markup_pct&.to_f }.compact.presence }.compact
        end
      end

      def packages
        @company.package_templates.where(is_active: true).order(:position).limit(30).map do |p|
          { name: p.name, default_price: money(p.default_price), taxable: p.taxable,
            counts_in_total: p.include_in_total, applies_to: p.try(:applicable_to) }.compact
        end.presence
      end

      def fees
        @company.fee_templates.where(active: true).order(:position).limit(30).map do |f|
          { name: f.name, type: f.fee_type, default_amount: money(f.default_amount), taxable: f.taxable }.compact
        end.presence
      end

      def sales_tax
        settings = AccountingSettings.for_company(@company)
        return 'Sales tax is not set up in Accounting Settings.' unless settings

        { tracking_on: settings.sales_tax_enabled,
          default_rates_percent: { state: settings.default_state_tax_rate&.to_f, county: settings.default_county_tax_rate&.to_f,
                                   city: settings.default_city_tax_rate&.to_f }.compact.presence,
          states_with_their_own_rates: (settings.tax_rates_by_state || {}).keys.first(20).presence,
          tax_codes: @company.tax_codes.where(is_active: true).order(:position).limit(15).map { |c| { name: c.name, rate: c.rate&.to_f } }.presence }.compact
      end
    end
  end
end
