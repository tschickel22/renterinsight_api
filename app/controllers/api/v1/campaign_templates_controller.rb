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
    return render(json: { error: 'from_identity_type and from_identity_id are required' }, status: :unprocessable_entity) if from_identity_type.blank? || from_identity_id.blank?

    campaign = nil
    ActiveRecord::Base.transaction do
      campaign = @company.campaigns.create!(
        name: params[:name].presence || "#{t.name} - #{Time.current.strftime('%b %-d')}",
        description: t.description,
        status: 'draft',
        channel: t.channel || 'email',
        campaign_type: t.steps_template.is_a?(Array) && t.steps_template.length > 1 ? 'drip' : 'blast',
        audience_mode: 'static',
        from_identity_type: from_identity_type,
        from_identity_id: from_identity_id,
        from_display_name: params[:from_display_name],
        goal_config: t.goal_config_template || {},
        send_window: t.send_window_template || {},
        utm_source: 'campaign',
        utm_medium: t.channel == 'sms' ? 'sms' : 'email',
        utm_campaign: t.slug,
        seeded_from_template_id: t.id,
        created_by_user_id: current_user.id,
        location_id: params[:location_id]
      )

      Array(t.steps_template).each_with_index do |step_blob, idx|
        campaign.campaign_steps.create!(
          position: idx,
          channel: step_blob['channel'] || t.channel || 'email',
          wait_days: step_blob['wait_days'] || 0,
          wait_hours: step_blob['wait_hours'] || 0,
          subject: step_blob['subject'],
          preheader: step_blob['preheader'],
          body_blocks: step_blob['body_blocks'] || [],
          sms_body: step_blob['sms_body'],
          media_url: step_blob['media_url'],
          inventory_block_config: step_blob['inventory_block_config']
        )
      end

      audience_hint = t.audience_hint || {}
      campaign.create_campaign_audience!(
        source_type: audience_hint['source_type'] || 'Lead',
        filter_tree: audience_hint['filter_tree'] || {}
      )
    end

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
