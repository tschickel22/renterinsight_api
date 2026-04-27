module Messaging
  class LinkTokenizer
    URL_REGEX = %r{https?://[^\s<>"'\)]+}i

    def initialize(campaign_send:, base_url:)
      @send = campaign_send
      @base_url = base_url.to_s.chomp('/')
    end

    def tokenize_html(html)
      return html if html.blank?
      doc = Nokogiri::HTML.fragment(html)
      doc.css('a[href]').each do |a|
        href = a['href']
        next if href.blank?
        next if skip?(href)
        a['href'] = wrap(href)
      end
      doc.to_html
    end

    def tokenize_text(text)
      return text if text.blank?
      text.gsub(URL_REGEX) do |url|
        skip?(url) ? url : wrap(url)
      end
    end

    private

    def skip?(href)
      return true if href.blank?
      return true if href.start_with?('mailto:', 'tel:', '#')
      return true if href.start_with?("#{@base_url}/t/")
      return true if href.start_with?("#{@base_url}/u/")
      false
    end

    def wrap(target_url)
      return target_url if @send&.id.blank? || @send.is_a?(CampaignSend) && @send.new_record?
      token = CampaignLinkToken.create!(
        campaign_id: @send.campaign_id,
        campaign_send_id: @send.id,
        target_url: target_url
      )
      "#{@base_url}/t/#{token.token}"
    end
  end
end
