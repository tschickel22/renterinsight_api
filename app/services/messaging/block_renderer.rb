module Messaging
  class BlockRenderer
    def initialize(blocks:, context:, company:, unsubscribe_url:, inventory_units: nil, branding: nil, contact: nil, referral_url: nil)
      @blocks = Array(blocks)
      @context = context
      @company = company
      @unsubscribe_url = unsubscribe_url
      @referral_url = referral_url
      @inventory_units = inventory_units || []
      @branding = branding || {}
      @contact  = contact  || {}
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
      when 'branded_header'    then render_branded_header(block)
      when 'sender_cta'        then render_sender_cta(block)
      when 'footer_unsubscribe' then render_footer
      else nil
      end
    end

    # Location/company branded band: logo + phone/address, brand-color accent
    # bar underneath. Silently renders nothing if we have no logo + no phone
    # + no name — safer than showing an empty dark band on a partially
    # configured tenant.
    def render_branded_header(_block)
      logo    = @branding[:logo_url] || @branding['logo_url']
      name    = @branding[:name]     || @branding['name']
      phone   = @branding[:phone]    || @branding['phone']
      address = @branding[:address]  || @branding['address']
      primary = @branding[:primary_color] || @branding['primary_color'] || '#3b82f6'
      return nil if logo.blank? && phone.blank? && name.blank?

      background  = header_background
      text_color  = ColorContrast.readable_text_on(background)
      muted_color = ColorContrast.muted_text_on(background)
      # A brand colour equal to the header colour renders a 5px bar that is not there. The
      # readable text colour is the fallback because it is guaranteed to contrast.
      accent = ColorContrast.visible_against(primary, background)

      logo_cell = if logo.present?
                    %(<img src="#{ERB::Util.html_escape(logo)}" alt="#{ERB::Util.html_escape(name.to_s)}" style="display:block;width:120px;height:auto;border:0;" />)
                  else
                    %(<div style="color:#{text_color};font-size:20px;font-weight:700;font-family:Arial,sans-serif;">#{ERB::Util.html_escape(name.to_s)}</div>)
                  end

      right_lines = []
      right_lines << %(<div style="font-size:22px;font-weight:700;letter-spacing:0.5px;color:#{text_color};">#{ERB::Util.html_escape(phone)}</div>) if phone.present?
      right_lines << %(<div style="font-size:12px;color:#{muted_color};margin-top:4px;">#{ERB::Util.html_escape(address)}</div>) if address.present?
      right_cell = right_lines.any? ? %(<td valign="middle" style="padding-left:16px;text-align:right;font-family:Arial,sans-serif;">#{right_lines.join}</td>) : ''

      %(<tr><td style="background:#{ERB::Util.html_escape(background)};padding:20px 24px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
          <tr>
            <td width="140" valign="middle">#{logo_cell}</td>
            #{right_cell}
          </tr>
        </table>
      </td></tr>
      <tr><td style="background:#{ERB::Util.html_escape(accent)};height:5px;font-size:0;line-height:0;">&nbsp;</td></tr>)
    end

    # The header band used to be hardcoded to #1f2937, which silently assumed every tenant's
    # logo was drawn for a dark background. A dealer whose wordmark is dark navy rendered as
    # a blank band with a sliver of whatever accent colour happened to be light enough.
    #
    # The default is now light, because dealer logos are overwhelmingly drawn for white
    # website headers. That is a better bet, not a guarantee: a logo drawn in white for a
    # dark background has the same problem in reverse, and nothing here can tell the
    # difference, because the logo is a URL and this codebase has no image processing (the
    # image_processing gem is commented out in the Gemfile). Tenants whose logo needs a dark
    # band set emailHeaderBackground in branding settings. Measuring the artwork at upload
    # time and choosing automatically is the real fix and is not done here.
    DEFAULT_HEADER_BACKGROUND = '#ffffff'

    def header_background
      configured = @branding[:header_background] || @branding['header_background']
      return DEFAULT_HEADER_BACKGROUND if configured.blank?
      # An unparseable value would otherwise reach the style attribute and be dropped by the
      # mail client, leaving a transparent band and text chosen for a colour that is not on
      # screen.
      return DEFAULT_HEADER_BACKGROUND if ColorContrast.parse(configured).nil?

      configured
    end

    # Sender contact card: rep name/title, email/phone, address, optional
    # "Schedule a tour" link if the rep has a booking_url. Falls back
    # location → company for missing fields (handled by ContactResolver).
    def render_sender_cta(block)
      name        = @contact[:name]          || @contact['name']
      title       = @contact[:title]         || @contact['title']
      email       = @contact[:email]         || @contact['email']
      phone       = @contact[:phone]         || @contact['phone']
      address     = @contact[:address]       || @contact['address']
      booking_url = @contact[:booking_url]   || @contact['booking_url']
      location    = @contact[:location_name] || @contact['location_name']
      primary     = @branding[:primary_color] || @branding['primary_color'] || '#3b82f6'
      return nil if name.blank? && email.blank? && phone.blank?

      cta_text = (block.is_a?(Hash) ? (block['cta_text'] || block[:cta_text]) : nil).presence || 'Schedule a tour'

      # Company/Location-type sends (no rep) fall the name through to the
      # location — which then shows up in the subline too, printing
      # "Denver Showroom" twice. Drop location from the subline when it's
      # already the name.
      subline_location = location.to_s == name.to_s ? nil : location
      subline = [title, subline_location].map(&:presence).compact.join(' · ')
      contact_line = [
        email.present? ? %(<a href="mailto:#{ERB::Util.html_escape(email)}" style="color:#374151;text-decoration:none;">#{ERB::Util.html_escape(email)}</a>) : nil,
        phone.present? ? ERB::Util.html_escape(phone) : nil
      ].compact.join(' · ')

      booking_html = booking_url.present? ?
        %(<div style="margin-top:10px;"><a href="#{ERB::Util.html_escape(booking_url)}" style="color:#{ERB::Util.html_escape(primary)};text-decoration:none;font-size:13px;font-weight:600;">#{ERB::Util.html_escape(cta_text)} &rarr;</a></div>) :
        ''

      %(<tr><td style="padding:8px 24px 0 24px;"><hr style="border:0;border-top:1px solid #e5e7eb;margin:8px 0;" /></td></tr>
      <tr><td style="padding:16px 24px 24px 24px;font-family:Arial,sans-serif;">
        #{name.present?    ? %(<div style="font-size:16px;font-weight:700;color:#1f2937;">#{ERB::Util.html_escape(name)}</div>) : ''}
        #{subline.present? ? %(<div style="font-size:13px;color:#6b7280;margin-top:2px;">#{ERB::Util.html_escape(subline)}</div>) : ''}
        #{contact_line.present? ? %(<div style="font-size:13px;color:#374151;margin-top:8px;">#{contact_line}</div>) : ''}
        #{address.present? ? %(<div style="font-size:13px;color:#6b7280;margin-top:2px;">#{ERB::Util.html_escape(address)}</div>) : ''}
        #{booking_html}
      </td></tr>)
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

    def render_inventory(block)
      return '' if @inventory_units.empty?
      layout = normalize_layout(block)
      cta_color = @branding[:primary_color] || @branding['primary_color'] || '#1f2937'

      cards = case layout
              when 'all_hero'
                @inventory_units.map { |u| inventory_hero_card(u, cta_color) }.join
              when 'all_rows'
                @inventory_units.map { |u| inventory_row_card(u, cta_color) }.join
              else # 'hero' — first unit big, rest as compact rows (motorcycle-style default)
                first, *rest = @inventory_units
                [inventory_hero_card(first, cta_color), *rest.map { |u| inventory_row_card(u, cta_color) }].join
              end

      %(<tr><td style="padding:8px 24px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
          #{cards}
        </table>
      </td></tr>)
    end

    def normalize_layout(block)
      raw = block.is_a?(Hash) ? (block['layout'] || block[:layout]) : nil
      case raw.to_s
      when 'all_hero', 'all_rows', 'hero' then raw.to_s
      else 'hero'
      end
    end

    def inventory_title(unit)
      "#{unit[:year]} #{unit[:make]} #{unit[:model]}".strip
    end

    def inventory_price(unit)
      unit[:sale_price] ? "$#{ActiveSupport::NumberHelper.number_to_delimited(unit[:sale_price].to_i)}" : ''
    end

    def inventory_bedbath(unit)
      [
        unit[:bedrooms].present?  ? "#{unit[:bedrooms]} bd"  : nil,
        unit[:bathrooms].present? ? "#{unit[:bathrooms]} ba" : nil
      ].compact.join(' &middot; ')
    end

    # Hero card — first unit or all_hero mode. Full-width image, centered
    # content, prominent CTA. Same visual weight as the old inventory_card
    # but with brand-color CTA button.
    def inventory_hero_card(unit, cta_color)
      title   = inventory_title(unit)
      price   = inventory_price(unit)
      bedbath = inventory_bedbath(unit)
      img_src = unit[:image_url].to_s
      url     = unit[:url] || '#'
      <<~HTML
        <tr><td style="padding:8px 0;">
          <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border:1px solid #e5e7eb;border-radius:8px;overflow:hidden;">
            <tr><td>
              #{img_src.present? ? %(<a href="#{ERB::Util.html_escape(url)}"><img src="#{ERB::Util.html_escape(img_src)}" alt="#{ERB::Util.html_escape(title)}" style="display:block;width:100%;height:auto;" /></a>) : ''}
            </td></tr>
            <tr><td style="padding:16px 20px;font-family:Arial,sans-serif;text-align:center;">
              <div style="font-size:18px;font-weight:700;color:#1f2937;">#{ERB::Util.html_escape(title)}</div>
              #{bedbath.present? ? %(<div style="font-size:14px;color:#6b7280;margin-top:6px;">#{bedbath}</div>) : ''}
              #{price.present?   ? %(<div style="font-size:20px;font-weight:800;color:#1f2937;margin-top:8px;">#{ERB::Util.html_escape(price)}</div>) : ''}
              <div style="margin-top:14px;">
                <a href="#{ERB::Util.html_escape(url)}" style="display:inline-block;background:#{ERB::Util.html_escape(cta_color)};color:#ffffff;padding:10px 24px;text-decoration:none;font-size:13px;font-weight:700;letter-spacing:1px;text-transform:uppercase;">View Details</a>
              </div>
            </td></tr>
          </table>
        </td></tr>
      HTML
    end

    # Compact row card — 160px left thumbnail, title/specs middle, small
    # brand-color CTA right. Matches the "list rows below the hero" pattern
    # from the motorcycle example. Falls back to hero if the unit has no
    # image (a tiny thumb slot looks worse than a hero placeholder).
    def inventory_row_card(unit, cta_color)
      return inventory_hero_card(unit, cta_color) if unit[:image_url].blank?

      title   = inventory_title(unit)
      price   = inventory_price(unit)
      bedbath = inventory_bedbath(unit)
      specs   = [bedbath.presence, price.presence].compact.join(' &middot; ')
      img_src = unit[:image_url].to_s
      url     = unit[:url] || '#'
      <<~HTML
        <tr><td style="padding:8px 0;">
          <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border:1px solid #e5e7eb;border-radius:8px;overflow:hidden;">
            <tr>
              <td width="160" style="padding:0;">
                <a href="#{ERB::Util.html_escape(url)}"><img src="#{ERB::Util.html_escape(img_src)}" alt="#{ERB::Util.html_escape(title)}" style="display:block;width:160px;height:120px;border:0;" /></a>
              </td>
              <td style="padding:10px 16px;vertical-align:middle;font-family:Arial,sans-serif;">
                <div style="font-size:15px;font-weight:600;color:#1f2937;">#{ERB::Util.html_escape(title)}</div>
                #{specs.present? ? %(<div style="font-size:13px;color:#6b7280;margin-top:4px;">#{specs}</div>) : ''}
              </td>
              <td width="130" style="padding:10px 16px;vertical-align:middle;text-align:right;">
                <a href="#{ERB::Util.html_escape(url)}" style="display:inline-block;background:#{ERB::Util.html_escape(cta_color)};color:#ffffff;padding:8px 14px;text-decoration:none;font-size:11px;font-weight:700;letter-spacing:1px;text-transform:uppercase;">View Details</a>
              </td>
            </tr>
          </table>
        </td></tr>
      HTML
    end

    def render_footer
      footer_html = UnsubscribeFooter.html_footer(company: @company, unsubscribe_url: @unsubscribe_url, referral_url: @referral_url)
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
