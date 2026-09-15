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

      # Seeded recurring templates carry their cadence inside the send window.
      # It used to be copied there and nowhere else, so "Weekly Inventory Digest
      # (recurring)" started as a one-time blast with a frozen recipient list.
      send_window = (@template.send_window_template || {}).deep_dup
      recurrence_cron = send_window.delete('recurrence_cron').presence
      recurring = recurrence_cron.present?

      campaign = nil
      ActiveRecord::Base.transaction do
        campaign = @company.campaigns.create!(
          name: @params[:name].presence || "#{@template.name} - #{Time.current.strftime('%b %-d')}",
          description: @template.description,
          status: 'draft',
          channel: @template.channel || 'email',
          campaign_type: campaign_type_for(recurring),
          # A recurring audience has to take in people tagged after launch.
          audience_mode: recurring ? 'dynamic' : 'static',
          recurrence_cron: recurrence_cron,
          from_identity_type: from_identity_type,
          from_identity_id: from_identity_id,
          from_display_name: @params[:from_display_name],
          goal_config: @template.goal_config_template || {},
          send_window: send_window,
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

        # deep_dup: the tag pass rewrites the tree in place, and the template's
        # own audience must stay as authored for the next company.
        audience_hint = (@template.audience_hint || {}).deep_dup
        filter_tree = AudienceTags.new(company: @company).prepare!(audience_hint['filter_tree'] || {})
        campaign.create_campaign_audience!(
          source_type: audience_hint['source_type'] || 'Lead',
          filter_tree: filter_tree
        )
      end
      campaign
    end

    private

    def campaign_type_for(recurring)
      return 'recurring_digest' if recurring
      @template.steps_template.is_a?(Array) && @template.steps_template.length > 1 ? 'drip' : 'blast'
    end
  end
end
