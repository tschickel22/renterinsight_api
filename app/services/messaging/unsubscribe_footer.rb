module Messaging
  module UnsubscribeFooter
    def self.html_footer(company:, unsubscribe_url:)
      address = format_address(company)
      url = unsubscribe_url.to_s.presence || '#'
      <<~HTML.strip
        <div style="margin-top:32px;padding-top:16px;border-top:1px solid #e5e7eb;font-size:12px;color:#6b7280;text-align:center;">
          <p style="margin:0 0 8px 0;">#{ERB::Util.html_escape(company&.name.to_s)}#{address.present? ? " &middot; #{ERB::Util.html_escape(address)}" : ''}</p>
          <p style="margin:0;">
            <a href="#{ERB::Util.html_escape(url)}" style="color:#6b7280;text-decoration:underline;">Unsubscribe</a>
          </p>
        </div>
      HTML
    end

    def self.format_address(company)
      return nil unless company
      parts = [company.try(:address1), company.try(:city), company.try(:state), company.try(:zip)].compact.reject(&:blank?)
      return nil if parts.empty?
      parts.join(', ')
    end
  end
end
