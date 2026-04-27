module Messaging
  class EmailRenderer
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

      inventory_units = nil
      blocks = Array(@step.body_blocks)
      inventory_block = blocks.find { |b| b.is_a?(Hash) && (b['type'] == 'inventory' || b[:type] == 'inventory') }

      if inventory_block
        config = @step.try(:inventory_block_config).presence || inventory_block
        result = InventoryBlockResolver.new(
          config: config, recipient: @recipient, company: @company, base_url: @base_url
        ).resolve

        case result[:fallback_action]
        when :abort_send
          return { error: 'inventory_empty_abort' }
        when :show_cta
          inventory_units = []
          blocks = blocks.map do |b|
            if b.is_a?(Hash) && (b['type'] == 'inventory' || b[:type] == 'inventory')
              { 'type' => 'button', 'text' => 'View all available homes', 'href' => urls[:public_inventory_url] || '#' }
            else
              b
            end
          end
        when :skip_block
          inventory_units = []
          blocks = blocks.reject { |b| b.is_a?(Hash) && (b['type'] == 'inventory' || b[:type] == 'inventory') }
        else
          inventory_units = result[:units]
        end
      end

      subject = MergeTagResolver.resolve(@step.subject || @campaign.try(:subject_default), context)

      raw_html = BlockRenderer.new(
        blocks: blocks, context: context, company: @company,
        unsubscribe_url: urls[:unsubscribe_url], inventory_units: inventory_units
      ).render

      tokenized = if @send && @send.persisted?
                    LinkTokenizer.new(campaign_send: @send, base_url: @base_url).tokenize_html(raw_html)
                  else
                    raw_html
                  end

      { subject: subject, html_body: tokenized, error: nil }
    end

    private

    def build_urls
      unsub = if @send && @send.persisted?
                token = Rails.application.message_verifier(:campaign_unsubscribe).generate({ 's' => @send.id })
                "#{@base_url.to_s.chomp('/')}/u/#{token}"
              else
                "#{@base_url.to_s.chomp('/')}/u/preview"
              end
      {
        unsubscribe_url: unsub,
        public_inventory_url: public_inventory_url,
        view_in_browser_url: nil
      }
    end

    def public_inventory_url
      return nil unless @company.respond_to?(:public_inventory_token) && @company.public_inventory_token.present?
      "#{@base_url.to_s.chomp('/')}/public/inventory/#{@company.public_inventory_token}"
    end
  end
end
