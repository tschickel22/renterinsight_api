# frozen_string_literal: true

module Websites
  # Public-safe payment calculator settings for a company.
  #
  # Extracted from Api::V1::WebsitesController#build_calculator_settings because
  # three other surfaces need the identical hash and none of them had it:
  #
  #   * Websites::PublicPayload — the SSR payload for live dealer domains. The
  #     in-app preview included calculator settings and the real site did not,
  #     so the calculator rendered in preview and vanished once published.
  #   * SiteContentProfilesController#by_token — the shared demo preview.
  #   * WebsitesController#showcase_inventory — the in-app design showcase.
  #
  # CalculatorBlock bails on `!settings || !settings.enabled`, so a missing key
  # is indistinguishable from "the dealer turned it off": the block silently
  # disappears rather than erroring. That is why this was invisible for so long.
  #
  # Keys are camelCase because they are consumed directly by the renderer.
  class CalculatorSettings
    DEFAULT_DISCLAIMER = 'This calculator provides estimates only. Actual rates, terms, and ' \
                         'payments may vary based on credit qualification and lender ' \
                         'requirements. Contact us for personalized financing options.'

    DEFAULT_TERM_OPTIONS = [120, 180, 240, 300, 360].freeze

    def self.for(company)
      new(company).to_h
    end

    def initialize(company)
      @settings = (company&.loan_settings || {})
    end

    def to_h
      {
        # Opt-out rather than opt-in: a dealer who has never opened the setting
        # still gets a working calculator.
        enabled: @settings['calculator_enabled'] != false,
        defaultInterestRate: num('default_interest_rate', 6.99),
        defaultLoanTermMonths: num('max_loan_term', 240).to_i,
        minDownPaymentPercent: num('min_down_payment_percent', 10),
        includeLotRent: flag('calculator_include_lot_rent'),
        defaultLotRentMonthly: num('calculator_default_lot_rent', 0),
        includePropertyTax: flag('calculator_include_property_tax'),
        defaultPropertyTaxRate: num('calculator_default_property_tax_rate', 1.0),
        includeInsurance: flag('calculator_include_insurance'),
        defaultInsuranceAnnual: num('calculator_default_insurance_annual', 0),
        includeSetupFee: flag('calculator_include_setup_fee'),
        defaultSetupFee: num('calculator_default_setup_fee', 0),
        loanTermOptions: term_options,
        disclaimerText: @settings['calculator_disclaimer_text'].presence || DEFAULT_DISCLAIMER
      }
    end

    # Monthly principal and interest for a price, using the company's own
    # configured rate, term and minimum down payment.
    #
    # Deliberately P&I only. Taxes, insurance, lot rent and setup are opt-in per
    # dealer and vary by placement, so folding them into a number printed on a
    # grid card would quote a payment we cannot stand behind. The full picture
    # is what the calculator block is for.
    #
    # @return [Float, nil] nil when the price or rate cannot produce a figure
    def monthly_payment_for(price)
      amount = price.to_f
      return nil unless amount.positive?

      principal = amount * (1 - (num('min_down_payment_percent', 10) / 100.0))
      return nil unless principal.positive?

      months = num('max_loan_term', 240).to_i
      return nil unless months.positive?

      monthly_rate = num('default_interest_rate', 6.99) / 100.0 / 12.0
      return (principal / months).round(2) if monthly_rate <= 0

      growth = (1 + monthly_rate)**months
      ((principal * monthly_rate * growth) / (growth - 1)).round(2)
    rescue StandardError
      nil
    end

    private

    def num(key, fallback)
      value = @settings[key]
      value.nil? || value.to_s.strip.empty? ? fallback.to_f : value.to_f
    end

    def flag(key)
      @settings[key] == true
    end

    def term_options
      raw = Array(@settings['calculator_loan_term_options']).map(&:to_i).select(&:positive?)
      raw.presence || DEFAULT_TERM_OPTIONS.dup
    end
  end
end
