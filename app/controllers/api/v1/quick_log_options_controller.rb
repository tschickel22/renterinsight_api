# frozen_string_literal: true

# The one-tap choices in Quick Log ("Left Message", "Set Appointment"), kept
# per company (Company Settings, Customize, Quick Log).
#
#   GET /api/v1/company/quick-log   { options: [...], defaults: [...] }
#   PUT /api/v1/company/quick-log   { options: [...] }
#
# Everyone logging calls reads them; changing them needs company_settings:update.
class Api::V1::QuickLogOptionsController < ApplicationController
  before_action :set_company_scope

  SETTING_KEY = 'quick_log_options'
  DEFAULTS = ['Left Message', 'No Answer', 'Spoke With Customer', 'Set Appointment', 'Sent Information', 'Not Interested'].freeze
  MAX_OPTIONS = 20
  MAX_LENGTH = 40

  def show
    render json: { options: self.class.options_for(@company), defaults: DEFAULTS }
  end

  def update
    return unless authorize_action!('company_settings', 'update')

    options = Array(params[:options]).map { |o| o.to_s.squish.first(MAX_LENGTH) }.reject(&:blank?).uniq(&:downcase).first(MAX_OPTIONS)
    Setting.set('Company', @company.id, SETTING_KEY, options)
    render json: { options: options, defaults: DEFAULTS }
  end

  # A company that never changed them has the defaults; one that cleared them has none.
  def self.options_for(company)
    saved = Setting.get('Company', company.id, SETTING_KEY, nil)
    saved.is_a?(Array) ? saved.map(&:to_s) : DEFAULTS.dup
  end
end
