# frozen_string_literal: true

require 'rails_helper'

# The step 3 setup readers (E118): texting and phone, agreement templates,
# and the deal sheet.
RSpec.describe 'Help setup readers' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}", industry: 'manufactured_housing', use_rbac_system: false) }
  let(:admin) do
    company.users.create!(email: "a-#{SecureRandom.hex(3)}@example.com", first_name: 'Ad', last_name: 'Min',
                          password: 'Pass1234!', role: 'admin', status: 'active')
  end
  let(:ctx) { Guide::AppContext.new(user: admin, company: company) }
  let!(:location) { company.locations.first || company.locations.create!(name: 'Main') }

  def skipped_facts
    msgs = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |orig, msg|
      msgs << msg if msg.to_s.include?('skipped a fact')
      orig.call(msg)
    end
    yield
    msgs
  end

  describe Guide::Setup::Texting do
    before do
      company.twilio_accounts.create!(phone_number: "+1720555#{rand(1000..9999)}", phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active', location_id: nil)
      Setting.set('Company', company.id, 'communications', { 'sms' => { 'fromNumber' => '+17205559999', 'twilioAuthToken' => 'TOKENSECRET' } })
    end

    it 'says which number texts go out from, and that changing the From number does not change it' do
      out = nil
      skipped = skipped_facts { out = described_class.new(ctx).to_h }
      expect(skipped).to be_empty, skipped.join("\n")
      expect(out[:texts_go_out_from].values).to all(eq(company.twilio_accounts.first.phone_number))
      expect(out[:from_number_in_settings][:note]).to include('does not change the number texts go out from')
      expect(out[:registration]).to include('No texting registration')
      expect(out[:phone_system_3cx][:connected]).to be(false)
      expect(out.to_json).not_to include('TOKENSECRET')
    end
  end

  describe Guide::Setup::Agreements do
    it 'lists signer slots and where each field comes from, never values' do
      company.agreement_templates.create!(
        name: 'Form 500', status: 'active',
        default_signers: [{ 'role' => 'signer', 'label' => 'Buyer', 'order_index' => 0 }, { 'role' => 'signer', 'label' => 'Co-Buyer', 'order_index' => 1 }],
        merge_field_placements: [
          { 'fieldKey' => 'contact.street', 'fieldLabel' => 'Buyer address', 'isSignerField' => false },
          { 'fieldKey' => 'signer.license_number', 'fieldLabel' => 'Driver license', 'isSignerField' => true, 'signerIndex' => 1 }
        ]
      )
      out = described_class.new(ctx).to_h
      t = out[:templates].first
      expect(t[:signer_slots].map { |s| s[:label] }).to eq(%w[Buyer Co-Buyer])
      expect(t[:fields_filled_from]["the buyer's contact record"]).to eq(['Buyer address'])
      expect(t[:signer_boxes]['slot 2']).to eq(['Driver license'])
    end
  end

  describe Guide::Setup::DealSheet do
    it 'reads pack, price book terms, fees and tax' do
      company.update_columns(default_pack_amount: 1_500) if company.has_attribute?(:default_pack_amount)
      company.dealer_catalog_terms.create!(doc_fee: 495, dealer_pack: 1_000)
      company.fee_templates.create!(name: 'Document Fee', fee_type: 'doc', default_amount: 495, active: true)
      out = nil
      skipped = skipped_facts { out = described_class.new(ctx).to_h }
      expect(skipped).to be_empty, skipped.join("\n")
      expect(out[:pack][:order]).to include("location's default")
      expect(out[:price_book_terms].first).to include(builder: 'all builders (company-wide)', doc_fee: 495.0)
      expect(out[:fees].map { |f| f[:name] }).to include('Document Fee')
    end
  end
end
