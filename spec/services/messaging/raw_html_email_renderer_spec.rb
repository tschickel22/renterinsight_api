# frozen_string_literal: true

require 'rails_helper'

# Option A: a campaign step whose body is a pasted, fully-designed HTML document
# must be sent as-is — merge tags resolved, an optional unsubscribe footer
# appended — WITHOUT the block layout wrapper (600px table) or the injected
# branded header / sender CTA that normal block-based steps get.
RSpec.describe Messaging::EmailRenderer, type: :service do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                     campaign_type: 'drip', from_identity_type: 'User', from_identity_id: user.id,
                     throttle_per_day: 100)
  end
  let(:lead) { Lead.create!(company_id: company.id, first_name: 'Jane', last_name: 'Doe', email: 'jane@x.com', status: 'new') }

  let(:designed_html) do
    '<!DOCTYPE html><html><head><style>.h{color:red}</style></head>' \
      '<body><table width="720"><tr><td class="h">Hello {{first_name}}</td></tr></table></body></html>'
  end

  def render_step(block)
    step = campaign.campaign_steps.create!(position: 0, subject: 'Hi {{first_name}}', body_blocks: [block])
    described_class.new(step: step, recipient: lead, campaign: campaign,
                        campaign_send: nil, company: company, base_url: 'https://app.test').render
  end

  it 'sends the designed HTML intact — table, <style>, and 720px width preserved' do
    out = render_step({ 'type' => 'raw_html', 'html' => designed_html, 'append_unsubscribe' => false })
    expect(out[:error]).to be_nil
    expect(out[:html_body]).to include('<table width="720">')
    expect(out[:html_body]).to include('<style>.h{color:red}</style>')
  end

  it 'does NOT double-wrap in the 600px block layout or inject header/CTA' do
    out = render_step({ 'type' => 'raw_html', 'html' => designed_html, 'append_unsubscribe' => false })
    expect(out[:html_body]).not_to include('max-width:600px')   # BlockRenderer#wrap
    expect(out[:html_body]).not_to include('branded_header')
    # exactly one <body> — not nested inside another document
    expect(out[:html_body].scan(/<body/i).size).to eq(1)
  end

  it 'resolves merge tags in both subject and body' do
    out = render_step({ 'type' => 'raw_html', 'html' => designed_html, 'append_unsubscribe' => false })
    expect(out[:subject]).to eq('Hi Jane')
    expect(out[:html_body]).to include('Hello Jane')
    expect(out[:html_body]).not_to include('{{first_name}}')
  end

  it 'appends the unsubscribe footer before </body> when the toggle is on (default)' do
    out = render_step({ 'type' => 'raw_html', 'html' => designed_html }) # no append_unsubscribe key -> default true
    expect(out[:html_body]).to include('Unsubscribe')
    expect(out[:html_body].index('Unsubscribe')).to be < out[:html_body].index('</body>')
  end

  it 'omits the unsubscribe footer when the toggle is off (design carries its own)' do
    out = render_step({ 'type' => 'raw_html', 'html' => designed_html, 'append_unsubscribe' => false })
    expect(out[:html_body]).not_to include('>Unsubscribe<')
  end
end
