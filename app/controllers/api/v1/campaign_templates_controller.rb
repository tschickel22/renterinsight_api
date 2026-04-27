class Api::V1::CampaignTemplatesController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('campaigns', 'read')

    templates = CampaignTemplate.active.for_company_or_seeded(@company.id)
    templates = templates.where(category: params[:category]) if params[:category].present?
    templates = templates.where(vertical: params[:vertical]) if params[:vertical].present?

    render json: { items: templates.map { |t| template_json(t) } }
  end

  def show
    return unless authorize_action!('campaigns', 'read')
    t = CampaignTemplate.for_company_or_seeded(@company.id).find(params[:id])
    render json: template_json(t, full: true)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Template not found' }, status: :not_found
  end

  def instantiate
    return unless authorize_action!('campaigns', 'create')
    t = CampaignTemplate.for_company_or_seeded(@company.id).find(params[:id])

    from_identity_type = params[:from_identity_type]
    from_identity_id = params[:from_identity_id]
    if (t.channel != 'sms') && (from_identity_type.blank? || from_identity_id.blank?)
      return render(json: { error: 'from_identity_type and from_identity_id are required' }, status: :unprocessable_entity)
    end

    campaign = Campaigns::TemplateInstantiator.new(
      template: t, company: @company, user: current_user,
      params: {
        name: params[:name],
        from_identity_type: from_identity_type,
        from_identity_id: from_identity_id,
        from_display_name: params[:from_display_name],
        location_id: params[:location_id]
      }
    ).call

    render json: { id: campaign.id, name: campaign.name, status: campaign.status }, status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Template not found' }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def template_json(t, full: false)
    base = {
      id: t.id, slug: t.slug, name: t.name, description: t.description,
      category: t.category, vertical: t.vertical,
      step_count: Array(t.steps_template).length,
      is_seeded: t.is_seeded
    }
    return base unless full
    base.merge(
      audience_hint: t.audience_hint, steps_template: t.steps_template,
      goal_config_template: t.goal_config_template, send_window_template: t.send_window_template
    )
  end
end
