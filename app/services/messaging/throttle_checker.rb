module Messaging
  class ThrottleChecker
    def initialize(campaign:, now: Time.current)
      @campaign = campaign
      @now = now
    end

    def check
      cap = (@campaign.throttle_per_day || 500).to_i
      sent_today_count = CampaignSend
        .where(campaign_id: @campaign.id)
        .where('sent_at >= ?', @now - 24.hours)
        .count

      return :throttled if cap > 0 && sent_today_count >= cap

      if @campaign.sms_channel?
        begin
          SmsCapService.check!(company: @campaign.company, source: 'campaign')
        rescue SmsCapService::CapExceededError
          return :throttled
        end
      end

      :ok
    end
  end
end
