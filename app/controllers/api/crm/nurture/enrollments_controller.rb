# frozen_string_literal: true
class Api::Crm::Nurture::EnrollmentsController < ApplicationController
  # JSON SPA calls won't send CSRF tokens (support API+HTML stacks)
  skip_before_action :verify_authenticity_token, raise: false

  # GET /api/crm/nurture/enrollments
  # Supports ?lead_id[]=1&lead_id[]=2 or ?lead_id=1
  def index
    scope = NurtureEnrollment.order(:id)
    lead_ids = params[:lead_id]
    lead_ids = [lead_ids] if lead_ids.is_a?(String)
    scope = scope.where(lead_id: lead_ids) if lead_ids.present?

    render json: scope.as_json(
      only: %i[id lead_id nurture_sequence_id status current_step_index created_at updated_at]
    ), status: :ok
  rescue => e
    render json: { error: 'server_error', message: e.message }, status: :internal_server_error
  end

  # POST /api/crm/nurture/enrollments/bulk
  # Body: { upsert:[{ id?, lead_id?, nurture_sequence_id?, status?, current_step_index? }], delete:[ids] }
  # Also accepts same under { enrollment: { ... } }
  def bulk
    payload = bulk_params
    upserts = Array(payload[:upsert])
    deletes = Array(payload[:delete])

    ActiveRecord::Base.transaction do
      upserts.each do |attrs|
        attrs = attrs.to_h.symbolize_keys

        # Normalize legacy FE value
        attrs[:status] = 'running' if attrs[:status] == 'active'

        rec =
          if attrs[:id].present?
            NurtureEnrollment.find_by(id: attrs[:id])
          elsif attrs[:lead_id].present? && attrs[:nurture_sequence_id].present?
            NurtureEnrollment
              .where(lead_id: attrs[:lead_id], nurture_sequence_id: attrs[:nurture_sequence_id])
              .where.not(status: 'completed')
              .order(:id)
              .first
          end

        if rec
          rec.update!(
            status: attrs[:status] || rec.status,
            current_step_index: attrs.key?(:current_step_index) ? attrs[:current_step_index] : rec.current_step_index
          )
        else
          NurtureEnrollment.create!(
            lead_id:             attrs.fetch(:lead_id),
            nurture_sequence_id: attrs.fetch(:nurture_sequence_id),
            status:              attrs[:status] || 'running',
            current_step_index:  attrs[:current_step_index] || 0
          )
        end
      end

      Array(deletes).each do |id|
        if (rec = NurtureEnrollment.find_by(id: id))
          rec.destroy!
        end
      end
    end

    head :no_content
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: 'validation_failed', messages: e.record&.errors&.full_messages || [e.message] },
           status: :unprocessable_entity
  rescue => e
    render json: { error: 'server_error', message: e.message }, status: :internal_server_error
  end

  private

  def bulk_params
    root = params[:enrollment].presence || params
    permitted_upserts =
      Array(root[:upsert]).map do |h|
        (h.is_a?(ActionController::Parameters) ? h : ActionController::Parameters.new(h))
          .permit(:id, :lead_id, :nurture_sequence_id, :status, :current_step_index)
      end
    permitted_deletes = Array(root[:delete])
    { upsert: permitted_upserts, delete: permitted_deletes }
  end
end
