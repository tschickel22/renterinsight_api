# frozen_string_literal: true

require 'rails_helper'

# Leads that arrive on their own (intake form, partner API, Facebook) wait in
# one queue until a person reaches out. Unassigned ones included, since every
# other lead queue is owner-only and never showed them.
RSpec.describe 'Inbound leads work queue', type: :model do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:location) { Location.create!(company_id: company.id, name: 'Lot', code: "LOT-#{SecureRandom.hex(2)}", active: true) }
  let(:user) do
    User.create!(email: "wqi-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Reid', last_name: 'Tester', role: 'admin')
  end
  let(:other_rep) do
    User.create!(email: "wqo-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ona', last_name: 'Other')
  end

  def queue_ids
    WorkqueueService.new(company: company, user: user, queue_id: 'leads_inbound_new')
                    .items[:items].map { |r| r[:entity_id] }
  end

  def inbound(**attrs)
    create(:lead, { company: company, status: 'new', origin: Lead::ORIGIN_INTAKE_FORM,
                    location_id: location.id }.merge(attrs))
  end

  it 'shows new leads from every inbound channel, mine and unassigned' do
    mine       = inbound(owner_id: user.id)
    via_api    = inbound(owner_id: nil, origin: Lead::ORIGIN_API)
    via_fb     = inbound(owner_id: nil, origin: Lead::ORIGIN_FACEBOOK)

    expect(queue_ids).to include(mine.id, via_api.id, via_fb.id)
  end

  it "leaves out leads keyed in by hand and another rep's leads" do
    manual  = create(:lead, company: company, status: 'new', owner_id: user.id)
    theirs  = inbound(owner_id: other_rep.id)

    expect(queue_ids).not_to include(manual.id, theirs.id)
  end

  it 'drops a lead once a person has contacted it or moved its status' do
    contacted = inbound(owner_id: user.id)
    Communication.create!(communicable: contacted, direction: 'outbound', channel: 'email', provider: 'smtp', from_address: 'rep@example.com', to_address: 'lead@example.com',
                          status: 'sent', subject: 'Hi', body: 'Hi', sent_at: Time.current,
                          metadata: { 'sender_user_id' => user.id })
    called = inbound(owner_id: user.id)
    LeadActivity.create!(lead_id: called.id, user_id: user.id, activity_type: 'call', subject: 'Intro call',
                         status: 'completed', completed_at: Time.current, call_direction: 'outbound')
    worked = inbound(owner_id: user.id, status: 'contacted')

    expect(queue_ids).not_to include(contacted.id, called.id, worked.id)
  end

  it 'keeps a lead that has only had an automated email' do
    lead = inbound(owner_id: user.id)
    Communication.create!(communicable: lead, direction: 'outbound', channel: 'email', provider: 'smtp', from_address: 'rep@example.com', to_address: 'lead@example.com',
                          status: 'sent', subject: 'Welcome', body: 'Welcome', sent_at: Time.current,
                          metadata: { 'category' => 'nurture' })

    expect(queue_ids).to include(lead.id)
  end

  it 'hides unassigned leads at a location the rep cannot work' do
    rep = other_rep
    lead = inbound(owner_id: nil)

    ids = WorkqueueService.new(company: company, user: rep, queue_id: 'leads_inbound_new')
                          .items[:items].map { |r| r[:entity_id] }
    expect(ids).not_to include(lead.id)
  end
end
