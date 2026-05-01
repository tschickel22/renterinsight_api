module Messaging
  module PixelInjector
    def self.inject(html, communication_id:, base_url:)
      return html if html.blank? || communication_id.blank?
      # Prevent double-injection — campaign emails already have a pixel.
      return html if html.include?('pixel.gif') && html.include?('/webhooks/email/')

      pixel = pixel_tag(communication_id, base_url)
      if html.include?('</body>')
        html.sub('</body>', "#{pixel}</body>")
      else
        html + pixel
      end
    end

    def self.pixel_tag(communication_id, base_url)
      url = "#{base_url.to_s.chomp('/')}/webhooks/email/#{communication_id}/pixel.gif"
      %(<img src="#{url}" width="1" height="1" alt="" style="display:block;width:1px;height:1px;border:0;" />)
    end
  end
end
