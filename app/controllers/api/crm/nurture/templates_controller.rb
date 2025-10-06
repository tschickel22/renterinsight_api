# frozen_string_literal: true
class Api::Crm::Nurture::TemplatesController < ApplicationController
  # GET /api/crm/nurture/templates
  def index
    templates = Template.order(:id)
    render json: templates.as_json(
      only: %i[id name template_type subject body is_active created_at updated_at]
    ), status: :ok
  end

  # POST /api/crm/nurture/templates/bulk
  # Accepts { upsert:[{id?, name, template_type|channel, subject?, body?, is_active?}, ...], delete:[ids] }
  def bulk
    payload = bulk_params
    upsert  = Array(payload[:upsert]).map { |h| normalize_template_attrs(h.to_h.symbolize_keys) }
    deletes = Array(payload[:delete])

    ActiveRecord::Base.transaction do
      upsert.each do |t|
        rec = t[:id].present? ? Template.find_by(id: t[:id]) : Template.new
        rec.assign_attributes(t.slice(:name, :template_type, :subject, :body, :is_active))
        rec.save!
      end
      Template.where(id: deletes).delete_all if deletes.present?
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
    # tolerate either root params or a (possibly empty) :template wrapper
    root =
      if params.key?(:template) && params[:template].present?
        params.require(:template)
      else
        params
      end

    root.permit(
      { delete: [] },
      upsert: %i[id name template_type channel subject body is_active]
    )
  end

  def normalize_template_attrs(h)
    # If FE sends `channel` ("email"|"sms"), map to template_type
    h[:template_type] ||= h.delete(:channel)
    h
  end
end
