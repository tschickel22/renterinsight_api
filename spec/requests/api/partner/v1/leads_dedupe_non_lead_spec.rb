# frozen_string_literal: true

require 'rails_helper'

# IdentityResolver matches inbound email/phone across leads, contacts AND
# accounts. Only the lead branch used to do anything: a Facebook inquiry whose
# email belonged to an existing CONTACT returned 202 and wrote nothing — no
# note, no notification, no lead. The inquiry left no trace inside the app and
# no search could find the person, because their name was never stored.
RSpec.describe 'Api::Partner::V1 Leads dedupe to non-lead records', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }

  let(:owner) do
    User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", first_name: 'O', last_name: 'W',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end

  let(:creator) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  let(:key) do
    ApiKey.new(company_id: company.id, name: 'Facebook Leads',
               key: "ri_live_#{SecureRandom.hex(24)}",
               permissions: { 'leads' => %w[read create] }, status: 'active',
               created_by_user_id: creator.id,
               webhook_config: { default_location_id: location.id, dedupe_enabled: true })
          .tap { |k| k.save!(validate: false) }
  end

  def post_inquiry(payload)
    post '/api/partner/v1/leads',
         params: payload.to_json,
         headers: { 'Authorization' => "Bearer #{key.key}", 'Content-Type' => 'application/json' }
  end

  context 'when the inquiry matches an existing contact' do
    let!(:contact) do
      Contact.create!(company_id: company.id, owner_id: owner.id,
                      first_name: 'Bob', last_name: 'Smith',
                      email: 'shared@example.com')
    end

    before do
      post_inquiry(full_name: 'Tia May', email: 'shared@example.com',
                   raw: { 'What are you looking for?' => 'Two bedroom' })
    end

    it 'reports the dedupe without creating a lead' do
      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body.dig('deduped_to', 'type')).to eq('contact')
      expect(body.dig('deduped_to', 'id')).to eq(contact.id)
      expect(Lead.where(company_id: company.id).count).to eq(0)
    end

    it 'writes a note naming the person who inquired' do
      note = Note.find_by(entity_type: 'contact', entity_id: contact.id.to_s)
      expect(note).to be_present
      expect(note.content).to include('REPEAT INQUIRY')
      expect(note.content).to include('Tia May')
      expect(note.content).to include('Two bedroom')
    end

    it 'records the inquiry on the contact itself' do
      expect(contact.reload.notes).to include('Tia May')
    end

    it 'notifies the contact owner, naming inquirer and matched record' do
      activity = ContactActivity.find_by(contact_id: contact.id, activity_type: 'reminder')
      expect(activity).to be_present
      expect(activity.assigned_to_id).to eq(owner.id)
      expect(activity.subject).to eq(
        'Repeat Inquiry on Existing Contact: Tia May (matched to existing record: Bob Smith)'
      )
    end

    it 'never overwrites the contact\'s own details' do
      expect(contact.reload.first_name).to eq('Bob')
      expect(contact.last_name).to eq('Smith')
    end
  end

  context 'when the inquiry matches an existing account' do
    let!(:account) do
      Account.create!(company_id: company.id, owner_id: owner.id,
                      name: 'Evangeline Homes', email: 'office@example.com')
    end

    before { post_inquiry(full_name: 'Tia May', email: 'office@example.com') }

    it 'reports the dedupe without creating a lead' do
      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body).dig('deduped_to', 'type')).to eq('account')
      expect(Lead.where(company_id: company.id).count).to eq(0)
    end

    it 'writes a note naming the person who inquired' do
      note = Note.find_by(entity_type: 'account', entity_id: account.id.to_s)
      expect(note).to be_present
      expect(note.content).to include('Tia May')
    end

    it 'notifies the account owner' do
      activity = AccountActivity.find_by(account_id: account.id, activity_type: 'reminder')
      expect(activity).to be_present
      expect(activity.subject).to eq(
        'Repeat Inquiry on Existing Account: Tia May (matched to existing record: Evangeline Homes)'
      )
    end

    it 'leaves the account fields untouched' do
      expect(account.reload.name).to eq('Evangeline Homes')
    end
  end
end
