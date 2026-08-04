# frozen_string_literal: true

require 'rails_helper'
require 'ostruct'

# WorkqueueService#enrich_message_targets resolves the "messageable contact" for
# each row — the lead/contact a user would email/text — walking deal/ticket to
# their contact and task/activity to their parent (and on to its contact).
RSpec.describe WorkqueueService, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@x.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:service) { described_class.new(company: company, user: user) }

  let(:contact) do
    Contact.create!(company_id: company.id, first_name: 'Jane', last_name: 'Doe',
                    email: 'jane@x.com', phone: '3035551212')
  end
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Lee', last_name: 'Ad',
                 email: 'lee@x.com', phone: '3035559999', status: 'new')
  end

  def make_deal(contact_id:)
    d = Deal.new(company_id: company.id, name: 'D1', contact_id: contact_id)
    d.save!(validate: false)
    d
  end

  def make_ticket(contact_id:)
    t = ServiceTicket.new(company_id: company.id, title: 'T1', contact_id: contact_id)
    t.save!(validate: false)
    t
  end

  def enrich(pairs)
    service.send(:enrich_message_targets, pairs)
    pairs.map(&:last)
  end

  it 'resolves a deal row to its contact (email/phone/target)' do
    deal = make_deal(contact_id: contact.id)
    item = enrich([[deal, { entity_type: 'deal', entity_id: deal.id }]]).first
    expect(item[:message_entity_type]).to eq('contact')
    expect(item[:message_entity_id]).to eq(contact.id)
    expect(item[:entity_email]).to eq('jane@x.com')
    expect(item[:entity_phone]).to eq('3035551212')
  end

  it 'resolves a service ticket row to its contact' do
    ticket = make_ticket(contact_id: contact.id)
    item = enrich([[ticket, { entity_type: 'ticket', entity_id: ticket.id }]]).first
    expect(item[:message_entity_type]).to eq('contact')
    expect(item[:message_entity_id]).to eq(contact.id)
  end

  it 'resolves a task on a deal to the deal’s contact' do
    deal = make_deal(contact_id: contact.id)
    task_rec = OpenStruct.new(taskable_type: 'Deal', taskable_id: deal.id)
    item = enrich([[task_rec, { entity_type: 'task', entity_id: 555 }]]).first
    expect(item[:message_entity_type]).to eq('contact')
    expect(item[:message_entity_id]).to eq(contact.id)
    expect(item[:entity_email]).to eq('jane@x.com')
  end

  it 'resolves a lead row to itself' do
    item = enrich([[lead, { entity_type: 'lead', entity_id: lead.id }]]).first
    expect(item[:message_entity_type]).to eq('lead')
    expect(item[:message_entity_id]).to eq(lead.id)
    expect(item[:entity_email]).to eq('lee@x.com')
  end

  # Hash queues (inventory_hot_interest) hand-build rows and have no backing AR
  # record to pass in — their lead/contact rows are self-referential, so
  # enrichment must work with a nil record.
  it 'resolves a hash-queue contact row with no backing record' do
    item = enrich([[nil, { entity_type: 'contact', entity_id: contact.id }]]).first
    expect(item[:message_entity_type]).to eq('contact')
    expect(item[:message_entity_id]).to eq(contact.id)
    expect(item[:entity_email]).to eq('jane@x.com')
    expect(item[:entity_phone]).to eq('3035551212')
  end

  it 'leaves no message target when the deal has no contact' do
    deal = make_deal(contact_id: nil)
    item = enrich([[deal, { entity_type: 'deal', entity_id: deal.id }]]).first
    expect(item[:message_entity_type]).to be_nil
    expect(item[:entity_email]).to be_blank
  end
end
