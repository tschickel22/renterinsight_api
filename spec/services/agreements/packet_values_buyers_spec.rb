# frozen_string_literal: true

require 'rails_helper'

# Tom, 2026-11-16: a buyer added only on the deal's Buyers card reaches the
# agreement packet. Buyer 1 is the deal's contact, Buyer 2 the co-applicant or
# else the next Buyers card person, and the names line lists everyone once.
RSpec.describe Agreements::PacketValues do
  let(:company) { Company.create!(name: "Buyers Co #{SecureRandom.hex(3)}") }
  let(:hannah) { company.contacts.create!(first_name: 'Hannah', last_name: 'Whitfield', city: 'Elkhart') }
  let(:ben) { company.contacts.create!(first_name: 'Ben', last_name: 'Whitfield', city: 'Goshen') }
  let(:ruth) { company.contacts.create!(first_name: 'Ruth', last_name: 'Ames') }

  def buyers_for(deal) = described_class.new(deal.reload).send(:buyers)

  it 'makes a Buyers card person Buyer 2 when the deal has no co-applicant' do
    deal = company.deals.create!(name: 'W', contact_id: hannah.id)
    EntityBuyer.create!(company: company, contact: hannah, buyable: deal, role: 'buyer', position: 0)
    EntityBuyer.create!(company: company, contact: ben, buyable: deal, role: 'co_buyer', position: 1)

    out = buyers_for(deal)
    expect(out['buyer_1.name']).to eq('Hannah Whitfield')
    expect(out['buyer_2.name']).to eq('Ben Whitfield')
    expect(out['buyer_2.city']).to eq('Goshen')
    expect(out['buyers.names']).to eq('Hannah Whitfield and Ben Whitfield')
  end

  it 'keeps the co-applicant as Buyer 2 and names a third buyer from the card' do
    deal = company.deals.create!(name: 'W', contact_id: hannah.id, co_applicant_contact_id: ben.id)
    EntityBuyer.create!(company: company, contact: ruth, buyable: deal, role: 'co_buyer', position: 0)

    out = buyers_for(deal)
    expect(out['buyer_2.name']).to eq('Ben Whitfield')
    expect(out['buyers.names']).to eq('Hannah Whitfield, Ben Whitfield and Ruth Ames')
  end

  it 'reads as before with no Buyers card' do
    deal = company.deals.create!(name: 'W', contact_id: hannah.id)

    out = buyers_for(deal)
    expect(out['buyers.names']).to eq('Hannah Whitfield')
    expect(out).not_to have_key('buyer_2.name')
  end
end
