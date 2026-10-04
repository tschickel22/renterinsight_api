# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PortalInvitationEmail do
  let(:company) { Company.create!(name: 'Summit Park Manufactured Homes') }
  let(:url) { 'https://example.test/client/register?token=abc' }
  let(:text) do
    "Hi Hank Wood,\n\nYou've been invited to access the Summit Park Manufactured Homes client portal!\n\n" \
      "Click here to create your account:\n#{url}\n\nBest regards,\nSummit Park Manufactured Homes"
  end

  it "lays a plain text invitation out as a branded email with a button, keeping the dealer's words" do
    html = described_class.html(company: company, url: url, text: text, expires_in: '7 days')
    expect(html).to include('<p style="margin:0 0 16px;">Hi Hank Wood,</p>')
    expect(html).to include('Click here to create your account</p>')
    expect(html).to include(%(href="#{url}"), '>Create your account</a>', 'This link works for 7 days.')
    expect(html).to include('Best regards,<br>Summit Park Manufactured Homes')
    expect(html).not_to match(/—|–/)
  end

  it 'leaves HTML a dealer wrote alone' do
    expect(described_class.html?('<p>Hello</p>')).to be(true)
    expect(described_class.html?(text)).to be(false)
  end
end
