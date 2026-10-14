# frozen_string_literal: true

# Company Settings, Customize, Appointments: when customers are reminded and
# whether they get calendar invites (Appointments::ReminderSettings).
#
#   GET /api/v1/company/appointment-reminders
#   PUT /api/v1/company/appointment-reminders   { enabled, offsets: [], channels: [], invites }
class Api::V1::AppointmentReminderSettingsController < ApplicationController
  before_action :set_company_scope

  def show
    render json: { settings: Appointments::ReminderSettings.for(@company), offsets: Appointments::ReminderSettings::OFFSETS.keys }
  end

  def update
    return unless authorize_action!('company_settings', 'update')

    saved = Appointments::ReminderSettings.save(@company, params.permit(:enabled, :invites, offsets: [], channels: []).to_h)
    render json: { settings: saved, offsets: Appointments::ReminderSettings::OFFSETS.keys }
  end
end
