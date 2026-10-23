# frozen_string_literal: true

# Who gets texts to the dealer's own or provisioned number that answer
# nothing they sent and come from someone not in the CRM (ColdTextHandler):
# one person, or a rotation between reps. Settings, SMS.
#
#   GET /api/v1/company/unmatched_texts
#   PUT /api/v1/company/unmatched_texts   { mode: user|round_robin|'', user_id?, rotation_user_ids? }
class Api::V1::UnmatchedTextsController < ApplicationController
  before_action :set_company_scope

  def show
    return unless authorize_action!('company_settings', 'read')

    render json: payload
  end

  def update
    return unless authorize_action!('company_settings', 'update')

    UnmatchedTextRouting.new(@company).save!(mode: params[:mode], user_id: params[:user_id],
                                             rotation_user_ids: params[:rotation_user_ids])
    render json: payload
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  # The numbers it applies to: texts to the shared platform number reach no
  # dealer, so with none of their own there is nothing to route.
  def payload
    numbers = TwilioAccount.active.where(company_id: @company.id).order(:id).map do |a|
      { phone_number: a.phone_number, own_account: a.own_account?, location: a.location&.name,
        # Easy Homesource's pattern: texts still go to another system.
        inbound_elsewhere: a.metadata.to_h['inbound_to'].present? }
    end
    { numbers: numbers, routing: UnmatchedTextRouting.new(@company).as_json }
  end
end
