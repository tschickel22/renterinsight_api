module Messaging
  class SmsRenderer
    def initialize(step:, recipient:, campaign:, campaign_send:, company:, base_url:)
      @step = step
      @recipient = recipient
      @campaign = campaign
      @send = campaign_send
      @company = company
      @base_url = base_url
    end

    def render
      urls = build_urls
      context = MergeTagResolver.build_context(
        recipient: @recipient, company: @company, rep: @campaign.try(:created_by),
        campaign_send: @send, urls: urls
      )
      body = MergeTagResolver.resolve(@step.sms_body, context)
      body = LinkTokenizer.new(campaign_send: @send, base_url: @base_url).tokenize_text(body) if @send && @send.persisted?
      { body: body, media_url: @step.try(:media_url) }
    end

    private

    def build_urls
      {
        public_inventory_url: (
          if @company.respond_to?(:public_inventory_token) && @company.public_inventory_token.present?
            "#{@base_url.to_s.chomp('/')}/public/inventory/#{@company.public_inventory_token}"
          end
        ),
        unsubscribe_url: nil
      }
    end
  end
end
