# frozen_string_literal: true

# The client portal invitation as a proper email: the dealer's logo and
# color, a button to create the account, and what the portal is for.
#
# Invitations are written as plain text templates (each dealer can edit
# theirs). Since the email service sends HTML by default, plain text went out
# as one run-on paragraph with a bare link, so the template's own words are
# laid out here: paragraphs kept, the link made a button.
module PortalInvitationEmail
  module_function

  # button: the call to action ("Create your account", or "Sign in" for a
  # buyer who already has one). expires_in: nil when the link does not expire.
  def html(company:, url:, text:, expires_in:, button: 'Create your account')
    branding = company.resolve_branding_for_inventory.with_indifferent_access
    color = branding[:primary_color].to_s.match?(/\A#\h{3,8}\z/) ? branding[:primary_color] : '#2563eb'
    logo = branding[:logo].presence
    name = ERB::Util.h(company.name)

    label = button
    paragraphs = text.to_s.strip.split(/\n\s*\n/).map(&:strip).reject(&:empty?)
    body = paragraphs.map do |p|
      if p.include?(url)
        before = p.sub(url, '').strip.sub(/:\z/, '')
        lead = before.empty? ? '' : %(<p style="margin:0 0 12px;">#{ERB::Util.h(before)}</p>)
        lead + button(url, color, label)
      else
        %(<p style="margin:0 0 16px;">#{ERB::Util.h(p).gsub("\n", '<br>')}</p>)
      end
    end
    body << button(url, color, label) unless text.to_s.include?(url)

    <<~HTML
      <!DOCTYPE html>
      <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
      <body style="margin:0;padding:0;background:#f4f5f7;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:24px 12px;">
          <tr><td align="center">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:10px;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1f2937;font-size:16px;line-height:1.6;">
              <tr><td style="padding:28px 32px 20px;border-bottom:4px solid #{color};text-align:center;">
                #{logo ? %(<img src="#{ERB::Util.h(logo)}" alt="#{name}" style="max-height:56px;max-width:220px;">) : %(<span style="font-size:22px;font-weight:700;color:#{color};">#{name}</span>)}
              </td></tr>
              <tr><td style="padding:28px 32px 8px;">
                #{body.join("\n")}
              </td></tr>
              <tr><td style="padding:0 32px 24px;">
                <div style="background:#f9fafb;border-radius:8px;padding:16px 20px;font-size:14px;color:#374151;">
                  <strong style="display:block;margin-bottom:6px;">In your portal you can</strong>
                  See the homes you designed and change or share them, review and accept quotes, sign and download
                  documents, follow your home's progress, and message #{name}.
                </div>
                <p style="margin:16px 0 0;font-size:13px;color:#6b7280;">
                  #{expires_in ? "This link works for #{ERB::Util.h(expires_in)}. " : ''}If the button does not work, paste this into your browser:<br>
                  <a href="#{ERB::Util.h(url)}" style="color:#{color};word-break:break-all;">#{ERB::Util.h(url)}</a>
                </p>
              </td></tr>
            </table>
          </td></tr>
        </table>
      </body></html>
    HTML
  end

  def button(url, color, label = 'Create your account')
    %(<p style="margin:8px 0 24px;text-align:center;"><a href="#{ERB::Util.h(url)}" style="display:inline-block;background:#{color};color:#ffffff;text-decoration:none;font-weight:600;padding:14px 28px;border-radius:8px;">#{ERB::Util.h(label)}</a></p>)
  end

  def html?(body)
    body.to_s.match?(/<(p|div|table|br|a|html|body)\b/i)
  end
end
