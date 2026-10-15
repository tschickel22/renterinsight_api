# frozen_string_literal: true

module Appointments
  # When customers are reminded of an appointment, per company (Company
  # Settings, Customize, Appointments). On by default (Tom, 2026-10-13); each
  # appointment can still opt out with its own "Remind the customer" box.
  module ReminderSettings
    KEY = 'appointment_reminders'
    OFFSETS = { 'day_before' => 24.hours, 'two_hours_before' => 2.hours, 'hour_before' => 1.hour }.freeze
    CHANNELS = %w[sms email].freeze
    DEFAULTS = { 'enabled' => true, 'offsets' => %w[day_before hour_before], 'channels' => %w[sms email], 'invites' => true }.freeze

    module_function

    def for(company)
      saved = Setting.get('Company', company.id, KEY, nil)
      saved = {} unless saved.is_a?(Hash)
      DEFAULTS.merge(saved.slice(*DEFAULTS.keys))
    end

    def save(company, params)
      clean = {
        'enabled' => ActiveModel::Type::Boolean.new.cast(params['enabled']) != false,
        'offsets' => Array(params['offsets']).map(&:to_s) & OFFSETS.keys,
        'channels' => Array(params['channels']).map(&:to_s) & CHANNELS,
        'invites' => ActiveModel::Type::Boolean.new.cast(params['invites']) != false
      }
      Setting.set('Company', company.id, KEY, clean)
      clean
    end
  end
end
