# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::Readiness do
  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.inbound_lead_location }
  let(:manager) do
    User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", first_name: 'Mia', last_name: 'Manager',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end

  before { allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false) }

  def readiness(play, installation = nil)
    result = described_class.new(play: play, company: company, installation: installation).call
    [result, result[:checks].index_by { |c| c[:key] }]
  end

  it 'tells a lead response play what is missing, and where to fix it' do
    installation = Plays::NewFacebookLead.new(company: company, user: manager,
                                              answers: { 'reps_by_location' => { location.id.to_s => [rep.id] } }).install!

    result, checks = readiness(Plays::NewFacebookLead, installation)

    expect(result[:ready]).to be true
    expect(checks['rotation']).to include(status: 'ok')
    expect(checks['mailboxes']).to include(status: 'warn', label: '0 of 1 reps have a connected mailbox',
                                           fix: { label: 'Connect a mailbox', path: '/account/settings?tab=email' })
    expect(checks['booking_links']).to include(status: 'warn', label: '1 rep has no booking link')
    expect(checks['texting']).to include(status: 'warn', label: 'No texting number')
    expect(checks['facebook']).to include(status: 'warn', label: 'Facebook Lead Ads not connected')
    expect(checks['company_email']).to include(status: 'warn')
    expect(checks['sending_domain']).to include(status: 'warn', fix: { label: 'Verify a sending domain', path: '/settings?tab=domains' })

    UserEmailConnection.create!(user_id: rep.id, company_id: company.id, provider: 'oauth_gmail', is_active: true,
                                email_address: rep.email, display_name: 'Rita Rep')
    rep.update!(booking_url: 'https://calendly.com/rita')
    _, checks = readiness(Plays::NewFacebookLead, installation)

    expect(checks['mailboxes']).to include(status: 'ok')
    expect(checks['booking_links']).to include(status: 'ok')
  end

  it 'has no Facebook check for a play that does not start from Facebook' do
    _, checks = readiness(Plays::WalkInVisit)

    expect(checks).not_to have_key('facebook')
    expect(checks).not_to have_key('rotation')
  end

  it 'counts homes to show and quiet leads to wake' do
    lead = Lead.create!(company_id: company.id, owner_id: rep.id, first_name: 'Quiet', email: 'quiet@example.com')
    lead.update_columns(last_activity_at: 90.days.ago)

    _, weekly = readiness(Plays::WeeklyHomesEmail)
    expect(weekly['homes']).to include(status: 'warn', label: 'No available homes with photos')
    expect(weekly['mailboxes']).to include(label: '0 of 1 reps have a connected mailbox')

    _, cold = readiness(Plays::WakeUpColdLeads)
    expect(cold['quiet_leads']).to include(status: 'ok', label: '1 lead has been quiet for 60 days')
  end

  it 'is not ready when the plan has no landing pages' do
    result, checks = readiness(Plays::PromoLandingPage)

    expect(result[:ready]).to be false
    expect(checks['landing_pages']).to include(status: 'missing')
  end
end
