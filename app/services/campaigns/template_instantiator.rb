module Campaigns
  class TemplateInstantiator
    def initialize(template:, company:, user:, params: {})
      @template = template
      @company = company
      @user = user
      @params = params || {}
    end

    def call
      from_identity_type = @params[:from_identity_type] || (@template.channel == 'sms' ? 'Company' : 'User')
      from_identity_id = @params[:from_identity_id] || (@template.channel == 'sms' ? @company.id : @user.id)

      campaign = nil
      ActiveRecord::Base.transaction do
        campaign = @company.campaigns.create!(
          name: @params[:name].presence || "#{@template.name} - #{Time.current.strftime('%b %-d')}",
          description: @template.description,
          status: 'draft',
          channel: @template.channel || 'email',
          campaign_type: @template.steps_template.is_a?(Array) && @template.steps_template.length > 1 ? 'drip' : 'blast',
          audience_mode: 'static',
          from_identity_type: from_identity_type,
          from_identity_id: from_identity_id,
          from_display_name: @params[:from_display_name],
          goal_config: @template.goal_config_template || {},
          send_window: @template.send_window_template || {},
          utm_source: 'campaign',
          utm_medium: @template.channel == 'sms' ? 'sms' : 'email',
          utm_campaign: @template.slug,
          seeded_from_template_id: @template.id,
          created_by_user_id: @user.id,
          location_id: @params[:location_id]
        )

        Array(@template.steps_template).each_with_index do |step_blob, idx|
          campaign.campaign_steps.create!(
            position: idx,
            channel: step_blob['channel'] || @template.channel || 'email',
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

        audience_hint = @template.audience_hint || {}
        campaign.create_campaign_audience!(
          source_type: audience_hint['source_type'] || 'Lead',
          filter_tree: audience_hint['filter_tree'] || {}
        )
      end
      campaign
    end
  end
end
