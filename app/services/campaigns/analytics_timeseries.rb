module Campaigns
  class AnalyticsTimeseries
    DEFAULT_DAYS = 30
    MAX_DAYS = 365

    def initialize(campaign:, days: DEFAULT_DAYS, end_date: nil)
      @campaign = campaign
      @days = [days.to_i.clamp(1, MAX_DAYS), 1].max
      @end_date = (end_date.is_a?(Date) ? end_date : Date.current)
      @start_date = @end_date - (@days - 1).days
    end

    def buckets
      sends = sends_per_day
      events = events_per_day
      bounces = bounces_per_day

      (@start_date..@end_date).map do |date|
        key = date.iso8601
        {
          date: key,
          sent: sends[key] || 0,
          delivered: events.dig(key, 'delivered') || 0,
          opened: events.dig(key, 'opened') || 0,
          clicked: events.dig(key, 'clicked') || 0,
          replied: events.dig(key, 'replied') || 0,
          bounced: bounces[key] || 0
        }
      end
    end

    def totals
      buckets_data = buckets
      {
        sent: buckets_data.sum { |b| b[:sent] },
        delivered: buckets_data.sum { |b| b[:delivered] },
        opened: buckets_data.sum { |b| b[:opened] },
        clicked: buckets_data.sum { |b| b[:clicked] },
        replied: buckets_data.sum { |b| b[:replied] },
        bounced: buckets_data.sum { |b| b[:bounced] }
      }
    end

    private

    def sends_per_day
      @campaign.campaign_sends.real
        .where('sent_at >= ? AND sent_at < ?', @start_date.beginning_of_day, (@end_date + 1.day).beginning_of_day)
        .where.not(sent_at: nil)
        .group("DATE(sent_at)")
        .count
        .transform_keys { |d| d.is_a?(Date) ? d.iso8601 : d.to_s }
    end

    def events_per_day
      base = @campaign.campaign_sends.real
                     .where('sent_at >= ? AND sent_at < ?', @start_date.beginning_of_day, (@end_date + 1.day).beginning_of_day)

      result = {}

      %w[delivered opened clicked replied].each do |event_type|
        col = "#{event_type}_at"
        next unless CampaignSend.column_names.include?(col)

        counts = base.where.not(col => nil)
                    .group("DATE(#{col})")
                    .count
                    .transform_keys { |d| d.is_a?(Date) ? d.iso8601 : d.to_s }

        counts.each do |date, count|
          result[date] ||= {}
          result[date][event_type] = count
        end
      end

      result
    end

    def bounces_per_day
      @campaign.campaign_sends.real
        .where('bounced_at >= ? AND bounced_at < ?', @start_date.beginning_of_day, (@end_date + 1.day).beginning_of_day)
        .where.not(bounced_at: nil)
        .group("DATE(bounced_at)")
        .count
        .transform_keys { |d| d.is_a?(Date) ? d.iso8601 : d.to_s }
    end
  end
end
