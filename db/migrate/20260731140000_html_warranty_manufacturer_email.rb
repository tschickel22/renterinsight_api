# frozen_string_literal: true

# The claim email a manufacturer receives was seeded as plain text
# (20251205000000) but every email in this app is delivered as text/html. HTML
# collapses runs of whitespace, so the whole claim — headings, parts list, the
# bulleted "you can approve / request info / deny" — arrived as one unbroken
# paragraph, and the only way to act on it was a bare URL buried mid-sentence.
#
# Rewrite the platform default as real email HTML: table layout, inline styles,
# and three buttons that deep-link into the public claim page with the matching
# action already open. Company templates (company_id present) are left alone —
# find_template prefers those, and they are the dealer's to edit.
class HtmlWarrantyManufacturerEmail < ActiveRecord::Migration[8.0]
  BODY = <<~'HTML'
    <div style="margin:0;padding:0;background:#f4f5f7;">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#f4f5f7;padding:24px 12px;">
        <tr>
          <td align="center">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" style="max-width:600px;width:100%;background:#ffffff;border-radius:8px;border:1px solid #e4e6eb;font-family:Arial,Helvetica,sans-serif;color:#1f2937;">

              <tr>
                <td style="padding:24px 32px 8px 32px;">
                  <p style="margin:0 0 4px 0;font-size:13px;color:#6b7280;">New warranty claim from {{company_name}}</p>
                  <h1 style="margin:0;font-size:22px;line-height:28px;color:#111827;">Claim {{claim_number}}</h1>
                </td>
              </tr>

              <tr>
                <td style="padding:12px 32px 0 32px;font-size:15px;line-height:22px;">
                  <p style="margin:0 0 16px 0;">Dear {{manufacturer_name}},</p>
                  <p style="margin:0 0 20px 0;">A new warranty claim has been submitted for your review.</p>
                </td>
              </tr>

              <tr>
                <td style="padding:0 32px;">
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:6px;font-size:14px;line-height:20px;">
                    <tr><td style="padding:14px 16px 4px 16px;font-size:12px;font-weight:bold;letter-spacing:.6px;text-transform:uppercase;color:#6b7280;">Claim details</td></tr>
                    <tr><td style="padding:0 16px 14px 16px;">
                      <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="font-size:14px;line-height:20px;">
                        <tr><td style="padding:3px 0;color:#6b7280;width:45%;">Claim number</td><td style="padding:3px 0;color:#111827;">{{claim_number}}</td></tr>
                        <tr><td style="padding:3px 0;color:#6b7280;">Submitted</td><td style="padding:3px 0;color:#111827;">{{claim_date}}</td></tr>
                        <tr><td style="padding:3px 0;color:#6b7280;">Dealer</td><td style="padding:3px 0;color:#111827;">{{company_name}}</td></tr>
                        <tr><td style="padding:3px 0;color:#6b7280;">Dealer code</td><td style="padding:3px 0;color:#111827;">{{dealer_code}}</td></tr>
                        <tr><td style="padding:3px 0;color:#6b7280;">Estimated amount</td><td style="padding:3px 0;color:#111827;font-weight:bold;">{{estimated_amount}}</td></tr>
                      </table>
                    </td></tr>
                  </table>
                </td>
              </tr>

              <tr>
                <td style="padding:20px 32px 0 32px;">
                  <p style="margin:0 0 8px 0;font-size:12px;font-weight:bold;letter-spacing:.6px;text-transform:uppercase;color:#6b7280;">Service ticket</p>
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="font-size:14px;line-height:20px;">
                    <tr><td style="padding:3px 0;color:#6b7280;width:45%;">Ticket</td><td style="padding:3px 0;color:#111827;">#{{ticket_number}}</td></tr>
                    <tr><td style="padding:3px 0;color:#6b7280;">Unit</td><td style="padding:3px 0;color:#111827;">{{vehicle_info}}</td></tr>
                    <tr><td style="padding:3px 0;color:#6b7280;">Customer</td><td style="padding:3px 0;color:#111827;">{{customer_name}}</td></tr>
                    <tr><td style="padding:3px 0;color:#6b7280;vertical-align:top;">Description</td><td style="padding:3px 0;color:#111827;">{{ticket_description}}</td></tr>
                  </table>
                </td>
              </tr>

              <tr>
                <td style="padding:20px 32px 0 32px;">
                  <p style="margin:0 0 8px 0;font-size:12px;font-weight:bold;letter-spacing:.6px;text-transform:uppercase;color:#6b7280;">Parts required</p>
                  <div style="font-size:14px;line-height:20px;color:#111827;">{{parts_list_html}}</div>
                </td>
              </tr>

              <tr>
                <td style="padding:20px 32px 0 32px;">
                  <p style="margin:0 0 8px 0;font-size:12px;font-weight:bold;letter-spacing:.6px;text-transform:uppercase;color:#6b7280;">Labor</p>
                  <div style="font-size:14px;line-height:20px;color:#111827;">{{labor_details_html}}</div>
                </td>
              </tr>

              <tr>
                <td style="padding:20px 32px 0 32px;">
                  <p style="margin:0 0 8px 0;font-size:12px;font-weight:bold;letter-spacing:.6px;text-transform:uppercase;color:#6b7280;">Notes from dealer</p>
                  <div style="font-size:14px;line-height:20px;color:#111827;">{{claim_notes_html}}</div>
                  <p style="margin:12px 0 0 0;font-size:13px;color:#6b7280;">{{photos_count}} photo(s)/document(s) included with this claim.</p>
                </td>
              </tr>

              <tr>
                <td style="padding:24px 32px 8px 32px;">
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-top:1px solid #e5e7eb;">
                    <tr><td style="padding-top:20px;">
                      <p style="margin:0 0 14px 0;font-size:15px;line-height:22px;color:#111827;font-weight:bold;">Review and respond</p>
                    </td></tr>
                  </table>

                  <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                    <tr>
                      <td style="padding:0 8px 10px 0;">
                        <a href="{{warranty_link}}?action=approve" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:6px;font-size:15px;font-weight:bold;">Approve claim</a>
                      </td>
                      <td style="padding:0 8px 10px 0;">
                        <a href="{{warranty_link}}?action=request_info" style="display:inline-block;background:#ffffff;color:#1f2937;text-decoration:none;padding:12px 22px;border-radius:6px;font-size:15px;font-weight:bold;border:1px solid #9ca3af;">Request more info</a>
                      </td>
                      <td style="padding:0 0 10px 0;">
                        <a href="{{warranty_link}}?action=deny" style="display:inline-block;background:#ffffff;color:#b91c1c;text-decoration:none;padding:12px 22px;border-radius:6px;font-size:15px;font-weight:bold;border:1px solid #fca5a5;">Deny claim</a>
                      </td>
                    </tr>
                  </table>

                  <p style="margin:8px 0 0 0;font-size:13px;line-height:19px;color:#6b7280;">
                    Buttons not working? Open the claim here:<br>
                    <a href="{{warranty_link}}" style="color:#2563eb;word-break:break-all;">{{warranty_link}}</a>
                  </p>
                </td>
              </tr>

              <tr>
                <td style="padding:22px 32px 28px 32px;">
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-top:1px solid #e5e7eb;">
                    <tr><td style="padding-top:16px;font-size:13px;line-height:20px;color:#6b7280;">
                      Questions? Contact {{company_name}} &mdash; {{company_phone}} &middot;
                      <a href="mailto:{{company_email}}" style="color:#2563eb;">{{company_email}}</a><br>
                      This is an automated notification from {{company_name}}'s warranty management system.
                    </td></tr>
                  </table>
                </td>
              </tr>

            </table>
          </td>
        </tr>
      </table>
    </div>
  HTML

  def up
    template = CommunicationTemplate.find_or_initialize_by(
      template_type: 'warranty_submitted_to_manufacturer',
      company_id: nil
    )

    template.assign_attributes(
      name: 'Warranty Claim Submitted to Manufacturer',
      channel: 'email',
      subject: 'New Warranty Claim #{{claim_number}} from {{company_name}}',
      body: BODY,
      is_active: true,
      is_default: true
    )

    template.save!
    say "Rewrote warranty_submitted_to_manufacturer as HTML with response buttons"
  end

  def down
    # Deliberately irreversible in content: rolling back would restore the
    # plain-text body that renders as one collapsed paragraph. Re-run
    # SeedWarrantyEmailTemplates if that is genuinely wanted.
    say "Not restoring the plain-text body — re-run SeedWarrantyEmailTemplates if needed"
  end
end
