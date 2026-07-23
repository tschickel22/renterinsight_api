# frozen_string_literal: true

require 'rails_helper'

# Lead conversion has always created a second Contact on the account from the
# lead's co_applicant_* fields, but the Deal only ever pointed at the PRIMARY
# contact — so the co-borrower was reachable from the Account and invisible on
# the Deal. deals.co_applicant_contact_id closes that gap.
#
# The FK deliberately points at the Contact rather than copying the four
# co_applicant_* values onto the deal, so editing the contact updates the deal
# view with no sync step and the two can't drift.
RSpec.describe 'Lead conversion → deal co-applicant link', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:account) { Account.create!(company_id: company.id, name: 'Crutchfield Household') }

  let(:primary) do
    Contact.create!(company_id: company.id, account_id: account.id, first_name: 'Frederick',
                    last_name: 'Crutchfield', email: 'fred@example.com', phone: '3164520887',
                    is_primary: true)
  end

  let(:co_applicant) do
    Contact.create!(company_id: company.id, account_id: account.id, first_name: 'Dana',
                    last_name: 'Crutchfield', email: 'dana@example.com', phone: '3165551234',
                    is_primary: false, notes: 'Co-applicant converted from lead #15310')
  end

  it 'exposes the co-applicant through the association without copying the values' do
    deal = Deal.create!(company_id: company.id, account_id: account.id, name: 'Deal',
                        contact_id: primary.id, co_applicant_contact_id: co_applicant.id,
                        stage: company.default_deal_stage, value: 0)

    expect(deal.co_applicant_contact).to eq(co_applicant)
    expect(deal.co_applicant_contact.email).to eq('dana@example.com')
    expect(deal.co_applicant_contact.phone).to eq('3165551234')

    # The Contact is the source of truth: an edit there shows on the deal with
    # no backfill or sync step. This is the property the FK buys us over copying
    # co_applicant_* columns onto deals.
    co_applicant.update!(phone: '3165559999')
    expect(deal.reload.co_applicant_contact.phone).to eq('3165559999')
  end

  it 'leaves the link null for deals with no co-applicant' do
    deal = Deal.create!(company_id: company.id, account_id: account.id, name: 'Cash deal',
                        contact_id: primary.id, stage: company.default_deal_stage, value: 0)

    expect(deal.co_applicant_contact_id).to be_nil
    expect(deal.co_applicant_contact).to be_nil
  end

  it 'nullifies the link rather than orphaning the deal when the contact is deleted' do
    deal = Deal.create!(company_id: company.id, account_id: account.id, name: 'Deal',
                        contact_id: primary.id, co_applicant_contact_id: co_applicant.id,
                        stage: company.default_deal_stage, value: 0)

    co_applicant.destroy

    expect(deal.reload.co_applicant_contact_id).to be_nil
    expect(Deal.find(deal.id)).to be_present
  end

  # The link is settable from the deal page after conversion, so these guard the
  # three ways the picker (or a hand-rolled API call) can go wrong.
  describe 'validation when set after conversion' do
    let(:deal) do
      Deal.create!(company_id: company.id, account_id: account.id, name: 'Deal',
                   contact_id: primary.id, stage: company.default_deal_stage, value: 0)
    end

    it 'accepts a contact on the same account' do
      deal.co_applicant_contact_id = co_applicant.id
      expect(deal).to be_valid
    end

    it 'rejects the primary applicant as their own co-applicant' do
      deal.co_applicant_contact_id = primary.id

      expect(deal).not_to be_valid
      expect(deal.errors[:co_applicant_contact_id].join).to match(/same person/i)
    end

    it 'rejects a contact belonging to another company' do
      other_company = Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'rv')
      foreign = Contact.create!(company_id: other_company.id, first_name: 'Foreign', last_name: 'Person')

      deal.co_applicant_contact_id = foreign.id

      expect(deal).not_to be_valid
      expect(deal.errors[:co_applicant_contact_id].join).to match(/this company/i)
    end

    it "rejects a contact on a different account within the same company" do
      other_account = Account.create!(company_id: company.id, name: 'Unrelated Household')
      stranger = Contact.create!(company_id: company.id, account_id: other_account.id,
                                 first_name: 'Someone', last_name: 'Else')

      deal.co_applicant_contact_id = stranger.id

      expect(deal).not_to be_valid
      expect(deal.errors[:co_applicant_contact_id].join).to match(/this deal's account/i)
    end

    it 'allows clearing the link' do
      deal.update!(co_applicant_contact_id: co_applicant.id)
      deal.co_applicant_contact_id = nil

      expect(deal).to be_valid
      expect { deal.save! }.not_to raise_error
    end
  end
end
