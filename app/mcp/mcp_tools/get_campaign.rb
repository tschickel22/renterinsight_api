# frozen_string_literal: true

module McpTools
  class GetCampaign < Base
    tool_name 'get_campaign'
    title 'Read a campaign'
    description 'One campaign in full: results, audience rules, sender and each step (wait, subject, text). ' \
                'Takes the campaign id from list_campaigns, e.g. campaign:12. Read only.'
    input_schema(properties: { id: { type: 'string' } }, required: ['id'])
    read_only!

    def self.perform(ctx, id:)
      MarketingAccess.require_campaigns!(ctx, 'read')
      campaign = ctx.company.campaigns.active.find(id.to_s.delete_prefix('campaign:').to_i)
      audience = campaign.campaign_audience
      payload = ListCampaigns.summary(ctx, campaign).merge(
        sender: campaign.from_identity_type == 'Owner' ? "each record's owner" : campaign.from_display_name.presence || campaign.from_identity_type,
        audience: audience && { record_type: audience.source_type, rules: audience.filter_tree },
        steps: campaign.campaign_steps.map do |s|
          {
            position: s.position, wait_days: s.wait_days, wait_hours: s.wait_hours, channel: s.channel || campaign.channel,
            subject: s.subject, sms_body: s.sms_body,
            text: Array(s.body_blocks).filter_map { |b| ActionController::Base.helpers.strip_tags(b['html'].to_s).presence if b.is_a?(Hash) }.join("\n\n").first(3000)
          }.compact
        end
      )
      Base::Result.new(payload: payload, count: 1)
    end
  end
end
