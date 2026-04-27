module Messaging
  class BlockRenderer
    def initialize(blocks:, context:, company:, unsubscribe_url:, inventory_units: nil)
      @blocks = Array(blocks)
      @context = context
      @company = company
      @unsubscribe_url = unsubscribe_url
      @inventory_units = inventory_units || []
    end

    def render
      rows = @blocks.map { |b| render_block(b) }.compact.reject(&:blank?)
      wrap(rows.join("\n"))
    end

    private

    def render_block(block)
      type = block.is_a?(Hash) ? (block['type'] || block[:type]).to_s : nil
      case type
      when 'text'              then render_text(block)
      when 'image'             then render_image(block)
      when 'button'            then render_button(block)
      when 'divider'           then render_divider
      when 'inventory'         then render_inventory(block)
      when 'footer_unsubscribe' then render_footer
      else nil
      end
    end

    def render_text(block)
      content = block['html'] || block['text'] || block[:html] || block[:text] || ''
      resolved = MergeTagResolver.resolve(content, @context)
      %(<tr><td style="padding:16px 24px;font-family:Arial,sans-serif;font-size:15px;line-height:1.6;color:#1f2937;">#{resolved}</td></tr>)
    end

    def render_image(block)
      src = block['src'] || block[:src]
      alt = block['alt'] || block[:alt] || ''
      href = block['href'] || block[:href]
      return nil if src.blank?
      img = %(<img src="#{ERB::Util.html_escape(src)}" alt="#{ERB::Util.html_escape(alt)}" style="display:block;max-width:100%;height:auto;border:0;" />)
      if href.present?
        resolved_href = MergeTagResolver.resolve(href, @context)
        img = %(<a href="#{ERB::Util.html_escape(resolved_href)}">#{img}</a>)
      end
      %(<tr><td style="padding:8px 24px;text-align:center;">#{img}</td></tr>)
    end

    def render_button(block)
      text = block['text'] || block[:text] || 'Click here'
      href = block['href'] || block[:href] || '#'
      resolved_text = MergeTagResolver.resolve(text, @context)
      resolved_href = MergeTagResolver.resolve(href, @context)
      %(<tr><td style="padding:16px 24px;text-align:center;">
        <a href="#{ERB::Util.html_escape(resolved_href)}" style="display:inline-block;background:#1f2937;color:#ffffff;padding:12px 28px;border-radius:6px;font-family:Arial,sans-serif;font-size:15px;text-decoration:none;font-weight:600;">#{ERB::Util.html_escape(resolved_text)}</a>
      </td></tr>)
    end

    def render_divider
      %(<tr><td style="padding:8px 24px;"><hr style="border:0;border-top:1px solid #e5e7eb;margin:0;" /></td></tr>)
    end

    def render_inventory(_block)
      return '' if @inventory_units.empty?
      cards = @inventory_units.map { |unit| inventory_card(unit) }.join
      %(<tr><td style="padding:8px 24px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
          #{cards}
        </table>
      </td></tr>)
    end

    def inventory_card(unit)
      title = "#{unit[:year]} #{unit[:make]} #{unit[:model]}".strip
      price = unit[:sale_price] ? "$#{ActiveSupport::NumberHelper.number_to_delimited(unit[:sale_price].to_i)}" : ''
      bedbath = [
        unit[:bedrooms].present? ? "#{unit[:bedrooms]} bd" : nil,
        unit[:bathrooms].present? ? "#{unit[:bathrooms]} ba" : nil
      ].compact.join(' &middot; ')
      img_src = unit[:image_url] || ''
      url = unit[:url] || '#'
      <<~HTML
        <tr><td style="padding:8px 0;">
          <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border:1px solid #e5e7eb;border-radius:8px;overflow:hidden;">
            <tr><td>
              #{img_src.present? ? %(<a href="#{ERB::Util.html_escape(url)}"><img src="#{ERB::Util.html_escape(img_src)}" alt="#{ERB::Util.html_escape(title)}" style="display:block;width:100%;height:auto;" /></a>) : ''}
            </td></tr>
            <tr><td style="padding:12px 16px;font-family:Arial,sans-serif;">
              <div style="font-size:16px;font-weight:600;color:#1f2937;">#{ERB::Util.html_escape(title)}</div>
              <div style="font-size:14px;color:#6b7280;margin-top:4px;">#{bedbath}</div>
              <div style="font-size:18px;font-weight:700;color:#1f2937;margin-top:8px;">#{ERB::Util.html_escape(price)}</div>
              <div style="margin-top:12px;"><a href="#{ERB::Util.html_escape(url)}" style="background:#1f2937;color:#ffffff;padding:8px 16px;border-radius:4px;text-decoration:none;font-size:13px;">View details</a></div>
            </td></tr>
          </table>
        </td></tr>
      HTML
    end

    def render_footer
      footer_html = UnsubscribeFooter.html_footer(company: @company, unsubscribe_url: @unsubscribe_url)
      %(<tr><td>#{footer_html}</td></tr>)
    end

    def wrap(content)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8" /></head>
        <body style="margin:0;padding:0;background:#f9fafb;">
          <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#f9fafb;padding:24px 0;">
            <tr><td align="center">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" style="background:#ffffff;max-width:600px;border-radius:8px;overflow:hidden;">
                #{content}
              </table>
            </td></tr>
          </table>
        </body></html>
      HTML
    end
  end
end
