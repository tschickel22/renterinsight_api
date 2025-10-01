class Api::Crm::Nurture::TemplatesController < ApplicationController
  # GET /api/crm/nurture/templates
  def index
    templates = Template.order(:id)
    render json: templates.as_json(
      only: [:id, :name, :template_type, :subject, :body, :is_active, :created_at, :updated_at]
    )
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
  end

  private

  def bulk_params
    # tolerate either root params or a (possibly empty) :template wrapper
    if params.key?(:template) && params[:template].present?
      params.require(:template).permit(
        { delete: [] },
        upsert: [:id, :name, :template_type, :channel, :subject, :body, :is_active]
      )
    else
      params.permit(
        { delete: [] },
        upsert: [:id, :name, :template_type, :channel, :subject, :body, :is_active]
      )
    end
  end

  def normalize_template_attrs(h)
    # If FE sends `channel` ("email"|"sms"), map to template_type
    h[:template_type] ||= h.delete(:channel)
    h
  end
end
