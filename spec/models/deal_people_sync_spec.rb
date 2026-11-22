# frozen_string_literal: true

require 'rails_helper'

# The deal's people card (entity_buyers) and its Buyer / Co-Buyer columns
# (contact_id, co_applicant_contact_id) name the same people whichever side
# changes (Tom, 2026-11-22).
RSpec.describe 'Deal people card sync' do
  let(:company) { Company.create!(name: "People Co #{SecureRandom.hex(3)}") }
  let(:account) { company.accounts.create!(name: 'Whitfield') }
  let(:hannah) { company.contacts.create!(first_name: 'Hannah', last_name: 'Whitfield', account: account) }
  let(:ben) { company.contacts.create!(first_name: 'Ben', last_name: 'Whitfield', account: account) }
  let(:ruth) { company.contacts.create!(first_name: 'Ruth', last_name: 'Ames', account: account) }

  def card(deal) = deal.reload.entity_buyers.active.ordered.pluck(:contact_id, :role)

  it 'puts the Buyer and Co-Buyer columns on the card when the deal is made' do
    deal = company.deals.create!(name: 'W', account: account, contact_id: hannah.id, co_applicant_contact_id: ben.id)
    expect(card(deal)).to eq([[hannah.id, 'buyer'], [ben.id, 'co_buyer']])
  end

  it 'follows a changed Co-Buyer column, keeping other people' do
    deal = company.deals.create!(name: 'W', account: account, contact_id: hannah.id, co_applicant_contact_id: ben.id)
    EntityBuyer.create!(company: company, contact: company.contacts.create!(first_name: 'G', account: account),
                        buyable: deal, role: 'guarantor', position: 5)

    deal.update!(co_applicant_contact_id: ruth.id)
    expect(card(deal).map(&:last)).to eq(%w[buyer co_buyer guarantor])
    expect(card(deal).map(&:first)).to include(ruth.id)
    expect(card(deal).map(&:first)).not_to include(ben.id)

    deal.update!(co_applicant_contact_id: nil)
    expect(card(deal).map(&:last)).to eq(%w[buyer guarantor])
  end

  it 'sets the Co-Buyer column when someone is added on the card' do
    deal = company.deals.create!(name: 'W', account: account, contact_id: hannah.id)
    EntityBuyer.create!(company: company, contact: ben, buyable: deal, role: 'co_buyer', position: 1)
    expect(deal.reload.co_applicant_contact_id).to eq(ben.id)

    EntityBuyer.create!(company: company, contact: ruth, buyable: deal, role: 'co_buyer', position: 2)
    expect(deal.reload.co_applicant_contact_id).to eq(ben.id) # the first Co-Buyer keeps Buyer 2
  end

  it 'clears the Co-Buyer column when that person is removed or made a Co-Signer' do
    deal = company.deals.create!(name: 'W', account: account, contact_id: hannah.id, co_applicant_contact_id: ben.id)
    row = deal.entity_buyers.active.find_by(contact_id: ben.id)

    row.update!(role: 'cosigner')
    expect(deal.reload.co_applicant_contact_id).to be_nil

    row.update!(role: 'co_buyer')
    expect(deal.reload.co_applicant_contact_id).to eq(ben.id)

    row.update!(is_deleted: true)
    expect(deal.reload.co_applicant_contact_id).to be_nil
  end

  it 'moves the Buyer column when someone else is made Buyer' do
    deal = company.deals.create!(name: 'W', account: account, contact_id: hannah.id)
    deal.entity_buyers.active.find_by(contact_id: hannah.id).update!(role: 'co_buyer')
    EntityBuyer.create!(company: company, contact: ruth, buyable: deal, role: 'buyer', position: 0)

    deal.reload
    expect(deal.contact_id).to eq(ruth.id)
    expect(deal.co_applicant_contact_id).to eq(hannah.id)
  end

  it 'allows one Buyer only' do
    deal = company.deals.create!(name: 'W', account: account, contact_id: hannah.id)
    second = EntityBuyer.new(company: company, contact: ben, buyable: deal, role: 'buyer')
    expect(second).not_to be_valid
    expect(second.errors[:base].join).to include('already has a Buyer')
  end

  it 'reads "Second <contact word>" for the second person unless the company set its own' do
    expect(company.resolved_labels['second_person']).to eq('Second Contact')
    Setting.set('Company', company.id, 'label_overrides', { 'contact' => 'Person' })
    expect(company.resolved_labels['second_person']).to eq('Second Person')
    Setting.set('Company', company.id, 'label_overrides', { 'contact' => 'Person', 'second_person' => 'Spouse' })
    expect(company.resolved_labels['second_person']).to eq('Spouse')
  end

  it 'fills an empty card from the columns, and lists a disagreement instead of overwriting it' do
    deal = company.deals.create!(name: 'W', account: account, contact_id: hannah.id, co_applicant_contact_id: ben.id)
    # An older deal: columns set, card empty.
    deal.entity_buyers.update_all(is_deleted: true)
    deal.ensure_people_from_pointers!
    expect(card(deal)).to eq([[hannah.id, 'buyer'], [ben.id, 'co_buyer']])

    # A card naming someone else as Co-Buyer is left for a person to settle.
    deal.entity_buyers.where(contact_id: ben.id).update_all(contact_id: ruth.id)
    deal.ensure_people_from_pointers!
    expect(deal.reload.people_conflicts).to eq([{ role: 'co_buyer', column_contact_id: ben.id, card_contact_id: ruth.id }])
  end

  it 'labels roles with the company words' do
    company.update!(industry: 'property_management')
    deal = company.deals.create!(name: 'W', account: account, contact_id: hannah.id, co_applicant_contact_id: ben.id)
    expect(deal.entity_buyers.active.ordered.map(&:role_label)).to eq(%w[Applicant Co-Applicant])
  end
end
