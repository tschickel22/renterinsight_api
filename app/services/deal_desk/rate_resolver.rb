# frozen_string_literal: true

module DealDesk
  # Resolves which APR to use for a structure. Pure — callers pass in the candidate
  # values (read from lender program / company settings / rep input elsewhere); this
  # only picks among them. Keeps the engine DB-free per the Phase 1 contract.
  #
  # Spec wording lists the sources as: lender-program tier rate -> company default -> manual override.
  # Interpreted here as PRECEDENCE (most-specific wins): an explicit manual override the rep
  # typed beats the program tier rate, which beats the company default. A rate of 0.0 is a
  # valid value (0% promo) and is honored — only nil means "not provided".
  #
  # NOTE: flagged for Tom — confirm override-wins is the intended precedence.
  module RateResolver
    module_function

    # Returns the resolved APR (whole-number percent) or nil if no source provided one.
    def resolve(tier_rate: nil, company_default: nil, manual_override: nil)
      return manual_override.to_f unless manual_override.nil?
      return tier_rate.to_f unless tier_rate.nil?
      return company_default.to_f unless company_default.nil?

      nil
    end

    # Same as resolve but records which source won — useful for AI explanations and audit.
    # Returns { rate:, source: } where source is :manual_override | :tier | :company_default | nil.
    def resolve_with_source(tier_rate: nil, company_default: nil, manual_override: nil)
      unless manual_override.nil?
        return { rate: manual_override.to_f, source: :manual_override }
      end
      return { rate: tier_rate.to_f, source: :tier } unless tier_rate.nil?
      return { rate: company_default.to_f, source: :company_default } unless company_default.nil?

      { rate: nil, source: nil }
    end
  end
end
