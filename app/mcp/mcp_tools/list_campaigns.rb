# frozen_string_literal: true

module McpTools
  class ListCampaigns < ListTool
    tool_name 'list_campaigns'
    title 'List email and text campaigns'
    description 'List email and text campaigns, newest first, with status and results (sent, delivered, opened, ' \
                'clicked, replied, bounced, unsubscribed) and open, click and reply rates. Read only.'
    input_schema(
      properties: {
        status: { type: 'string', enum: Campaign::STATUSES },
        channel: { type: 'string', enum: Campaign::CHANNELS },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: nil, channel: nil, limit: 20)
      MarketingAccess.require_campaigns!(ctx, 'read')
      rel = ctx.company.campaigns.active
      rel = rel.where(status: status) if status.present?
      rel = rel.where(channel: channel) if channel.present?
      rows = rel.order(created_at: :desc).limit(ctx.row_limit(limit)).to_a
      items = rows.map { |c| summary(ctx, c) }
      Base::Result.new(payload: { count: items.size, items: items }, count: items.size)
    end

    def self.summary(ctx, campaign)
      stats = (campaign.stats_cache || {}).stringify_keys
      sent = stats['total_sent'].to_i
      rate = ->(n) { sent.positive? ? (100.0 * n.to_i / sent).round(1) : nil }
      {
        id: "campaign:#{campaign.id}", name: campaign.name, status: campaign.status, channel: campaign.channel,
        type: campaign.campaign_type, scheduled_at: campaign.scheduled_at&.iso8601, created_at: campaign.created_at&.iso8601,
        url: MarketingAccess.campaign_url(ctx, campaign),
        results: {
          sent: sent, delivered: stats['delivered'].to_i, opened: stats['opened'].to_i, clicked: stats['clicked'].to_i,
          replied: stats['replied'].to_i, bounced: stats['bounced'].to_i, unsubscribed: stats['unsubscribed'].to_i,
          open_rate_pct: rate.call(stats['opened']), click_rate_pct: rate.call(stats['clicked']),
          reply_rate_pct: rate.call(stats['replied'])
        }
      }
    end
  end
end
