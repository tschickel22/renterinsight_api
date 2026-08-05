# frozen_string_literal: true

# How strictly a company runs warranty service: who may put dollar amounts on
# an issue, whether a manufacturer must pre-authorize the repair, and whether
# the technician's clock time or the manufacturer's flat-rate guide governs
# labor.
#
# The three industries differ sharply, so defaults are seeded per industry and
# then editable in Company Settings:
#
#   Auto  - The OEM publishes a flat-rate labor guide; the dealer bills the
#           guide's time, not the clock. The warranty labor rate and parts
#           markup are established with the OEM (in most US states via retail-
#           rate statutes) and locked. Technicians write the 3 C's and their
#           actual time; a warranty administrator normalizes to the op code and
#           submits. The person doing the work does not set the amount.
#
#   RV    - Same skeleton, but authorization comes first: the dealer requests
#           approval before the repair and the OEM returns an authorization
#           number with its own allowed hours. Component suppliers (chassis,
#           appliances) warrant separately from the coach builder, so one
#           ticket can legitimately involve several manufacturers.
#
#   MH    - Materially looser. There is usually no flat-rate guide; the dealer
#           and manufacturer settle per item, and the contractor's invoice is
#           very often simply the number. Amounts arrive late and from the
#           vendor.
#
# Stored via Setting under the 'service_warranty_policy' key.
class ServiceWarrantyPolicy
  SETTING_KEY = 'service_warranty_policy'

  # Who is permitted to put money on an issue.
  #
  # These are actor *kinds* the system can actually determine at request time,
  # not HR job titles: `contractor` arrives through the contractor portal,
  # `admin` is an effective admin, `staff` is any other authenticated internal
  # user. The app's `user.role` column is a mix of slugs and display names and
  # carries no warranty-specific taxonomy, so keying on it would not hold.
  ACTOR_KINDS = %w[contractor staff admin].freeze

  LABOR_TIME_SOURCES = %w[flat_rate_guide negotiated actual_hours].freeze
  LABOR_RATE_SOURCES = %w[approved_warranty_rate per_ticket vendor_invoice].freeze

  DEFAULTS = {
    'automotive' => {
      'labor_time_source' => 'flat_rate_guide',
      'labor_rate_source' => 'approved_warranty_rate',
      'require_preauth_for_warranty' => true,
      # Auto typically only pre-authorizes above a threshold; below it the
      # dealer repairs and files afterward.
      'preauth_threshold_amount' => 500.0,
      # The technician does not set the amount; a warranty administrator does.
      'amount_setter_roles' => %w[admin],
      'allow_vendor_invoice_as_amount' => false,
      'require_approval_before_submit' => true,
      'approver_roles' => %w[admin],
      'require_cause_and_correction' => true,
      'require_op_code' => true,
      'claim_submission_window_days' => 30,
      'warranty_labor_rate' => nil,
      'parts_markup_percent' => 40.0
    }.freeze,
    'rv' => {
      'labor_time_source' => 'flat_rate_guide',
      'labor_rate_source' => 'approved_warranty_rate',
      # RV OEMs authorize before the work, with no threshold.
      'require_preauth_for_warranty' => true,
      'preauth_threshold_amount' => 0.0,
      'amount_setter_roles' => %w[staff admin],
      'allow_vendor_invoice_as_amount' => false,
      'require_approval_before_submit' => true,
      'approver_roles' => %w[admin],
      'require_cause_and_correction' => true,
      'require_op_code' => false,
      'claim_submission_window_days' => 30,
      'warranty_labor_rate' => nil,
      'parts_markup_percent' => 30.0
    }.freeze,
    'manufactured_housing' => {
      'labor_time_source' => 'actual_hours',
      'labor_rate_source' => 'vendor_invoice',
      'require_preauth_for_warranty' => false,
      'preauth_threshold_amount' => nil,
      # The contractor's invoice is routinely the number, so contractors may
      # supply amounts here.
      'amount_setter_roles' => %w[contractor staff admin],
      'allow_vendor_invoice_as_amount' => true,
      'require_approval_before_submit' => false,
      'approver_roles' => %w[staff admin],
      'require_cause_and_correction' => false,
      'require_op_code' => false,
      'claim_submission_window_days' => 90,
      'warranty_labor_rate' => nil,
      'parts_markup_percent' => nil
    }.freeze
  }.freeze

  FALLBACK_INDUSTRY = 'manufactured_housing'

  attr_reader :settings, :industry

  def initialize(settings, industry:)
    @industry = industry.to_s
    @settings = defaults_for(@industry).merge(settings || {})
  end

  def self.for_company(company)
    new(Setting.get('Company', company.id, SETTING_KEY) || {}, industry: company.industry)
  end

  def self.save_for_company(company, attrs)
    policy = for_company(company)
    merged = policy.settings.merge((attrs || {}).stringify_keys.slice(*policy.settings.keys))
    Setting.set('Company', company.id, SETTING_KEY, merged)
    new(merged, industry: company.industry)
  end

  def self.defaults_for_industry(industry)
    DEFAULTS[industry.to_s] || DEFAULTS[FALLBACK_INDUSTRY]
  end

  def [](key)
    settings[key.to_s]
  end

  # Resolves the acting principal to one of ACTOR_KINDS. Contractors reach the
  # app through the contractor portal, which passes via_portal: true.
  def self.actor_kind_for(user, via_portal: false)
    return 'contractor' if via_portal
    return 'admin' if user.respond_to?(:effective_admin?) && user.effective_admin?

    'staff'
  end

  # Whether an actor of this kind may write dollar amounts onto an issue.
  def amount_setter?(actor_kind)
    Array(settings['amount_setter_roles']).include?(actor_kind.to_s)
  end

  def approver?(actor_kind)
    Array(settings['approver_roles']).include?(actor_kind.to_s)
  end

  def contractor_may_set_amounts?
    amount_setter?('contractor')
  end

  def vendor_invoice_allowed?
    !!settings['allow_vendor_invoice_as_amount']
  end

  def approval_required?
    !!settings['require_approval_before_submit']
  end

  def cause_and_correction_required?
    !!settings['require_cause_and_correction']
  end

  def uses_flat_rate?
    settings['labor_time_source'] == 'flat_rate_guide'
  end

  # Pre-auth applies when enabled and the issue clears the threshold. A nil or
  # zero threshold means every warranty issue needs authorization.
  def preauth_required_for?(amount)
    return false unless settings['require_preauth_for_warranty']

    threshold = settings['preauth_threshold_amount']
    return true if threshold.nil? || threshold.to_f.zero?

    amount.to_f >= threshold.to_f
  end

  def to_h
    settings.merge('industry' => industry, 'industry_defaults' => defaults_for(industry))
  end

  private

  def defaults_for(industry)
    self.class.defaults_for_industry(industry).dup
  end
end
