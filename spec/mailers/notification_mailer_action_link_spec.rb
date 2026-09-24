# frozen_string_literal: true

require 'rails_helper'

# A rep told by email that a lead was assigned to them had no way to reach it
# except opening the CRM and searching for the name. The link was missing
# because the mailer read the raw action_url column, which almost no
# notification sets: the URL is derived from the record it points at.
RSpec.describe NotificationMailer, type: :mailer do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@dealer.example", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Jocob', last_name: 'Jones',
                 email: 'jocob@example.com')
  end

  def notification_for(notifiable, **attrs)
    Notification.create!(
      recipient: rep, notification_type: 'lead_assigned', category: 'crm', priority: 'high',
      title: 'Lead Assigned to You', message: "Someone assigned lead '#{lead.full_name}' to you",
      notifiable: notifiable, company_id: company.id, **attrs
    )
  end

  # Quoted-printable turns "=" into "=3D" and wraps long lines, so anything
  # asserting on a URL with a query string has to decode first.
  def html_of(mail)
    (mail.html_part || mail).body.decoded
  end

  it 'links straight to the lead, and says so on the button' do
    mail = described_class.broadcast_notification(user: rep, notification: notification_for(lead))
    body = html_of(mail)

    expect(body).to include("/crm/leads/#{lead.id}")
    expect(body).to include('View Lead')
  end

  it 'builds an absolute URL on the configured app host' do
    mail = described_class.broadcast_notification(user: rep, notification: notification_for(lead))

    expect(html_of(mail)).to match(%r{https?://[^"]+/crm/leads/#{lead.id}})
  end

  # A caller that sets its own destination still wins.
  it 'honours an explicit action_url over the derived one' do
    n = notification_for(lead, action_url: '/crm/leads/999?tab=notes', action_text: 'Open it')
    body = html_of(described_class.broadcast_notification(user: rep, notification: n))

    expect(body).to include('/crm/leads/999?tab=notes')
    expect(body).to include('Open it')
  end

  it 'renders without a button when there is nothing to link to' do
    n = Notification.create!(
      recipient: rep, notification_type: 'system_announcement', category: 'system',
      priority: 'normal', title: 'Scheduled maintenance', message: 'Back shortly',
      company_id: company.id
    )

    expect { html_of(described_class.broadcast_notification(user: rep, notification: n)) }
      .not_to raise_error
  end
end
