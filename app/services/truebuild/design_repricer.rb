# frozen_string_literal: true

module Truebuild
  # Re-prices a dealer's saved designs after their prices move (they accepted
  # a new price book, or one applied automatically), so a rep can call a buyer
  # about an increase before the buyer finds it. The price the buyer was shown
  # stays in price_snapshot; today's goes in metadata.
  module DesignRepricer
    module_function

    WINDOW = 180.days

    def call(company)
      company.truebuild_designs.where('created_at >= ?', WINDOW.ago).includes(:variant, :vehicle).find_each do |d|
        shown = d.price_snapshot['show_prices'] ? d.price_snapshot['total'] : nil
        next if shown.nil?

        today = PricingEngine.new(company: company, variant: d.variant, option_ids: d.option_ids,
                                  location: d.vehicle&.location).call.totals[:retail]
        next if today.nil?

        d.update_columns(metadata: d.metadata.merge('price_today' => today, 'repriced_at' => Time.current.iso8601,
                                                    'price_change' => (today - shown.to_f).round(2)),
                         updated_at: Time.current)
      rescue ArgumentError
        next
      end
    end
  end
end
