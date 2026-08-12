# frozen_string_literal: true

require 'rails_helper'

# Cloning copies who the buyer is and what they want, and leaves behind
# everything the original earned. The cases that matter are the ones where a
# copied field would assert something untrue about the new record: money
# collected, consent given, a campaign credited, an external system's identity.
RSpec.describe 'Lead cloning', type: :request do
  # RBAC is exercised through its own suites; take skip_rbac?'s non-RBAC path.
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "clone-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Reid', last_name: 'Tester')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  let(:original) do
    create(:lead, company: company,
                  first_name: 'Katina', last_name: 'Harley',
                  email: 'katina@example.com', phone: '555-867-5309',
                  status: 'qualified', notes: 'Wants a 3 bed.')
  end

  def clone_it(lead = original)
    post "/api/crm/leads/#{lead.id}/clone", headers: headers
  end

  def cloned_lead
    Lead.find(JSON.parse(response.body)['id'])
  end

  describe 'POST /api/crm/leads/:id/clone' do
    it 'copies the profile onto a new record' do
      clone_it

      expect(response).to have_http_status(:created)
      copy = cloned_lead
      expect(copy.id).not_to eq(original.id)
      expect(copy.first_name).to eq('Katina')
      expect(copy.last_name).to eq('Harley')
      expect(copy.email).to eq('katina@example.com')
      expect(copy.phone).to eq('555-867-5309')
      expect(copy.company_id).to eq(company.id)
    end

    it 'starts the copy at the top of the pipeline' do
      clone_it

      expect(cloned_lead.status).to eq('new')
    end

    it 'records where the copy came from' do
      clone_it

      copy = cloned_lead
      expect(copy.notes).to include('Wants a 3 bed.')
      expect(copy.notes).to include("Cloned from lead ##{original.id}")
    end

    it 'leaves the original untouched' do
      clone_it

      original.reload
      expect(original.status).to eq('qualified')
      expect(original.notes).to eq('Wants a 3 bed.')
    end

    it 'does not carry over money collected on the original' do
      original.update!(deposit_amount: 5_000)

      clone_it

      expect(cloned_lead.deposit_amount).to be_nil
    end

    it 'does not carry over SMS consent' do
      original.update!(opt_in_sms: true)

      clone_it

      expect(cloned_lead.opt_in_sms).to be_falsey
    end

    it 'does not re-credit the campaign that produced the original' do
      original.update!(utm_source: 'facebook', utm_campaign: 'spring-promo')

      clone_it

      copy = cloned_lead
      expect(copy.utm_source).to be_nil
      expect(copy.utm_campaign).to be_nil
    end

    it 'does not duplicate the external system identity' do
      original.update!(champion_salesforce_id: 'SF-12345')

      clone_it

      expect(cloned_lead.champion_salesforce_id).to be_nil
    end

    it 'does not inherit the conversion of a converted lead' do
      original.update!(is_converted: true, converted_at: Time.current)

      clone_it

      copy = cloned_lead
      expect(copy.is_converted).to be_falsey
      expect(copy.converted_at).to be_nil
    end

    it 'refuses to clone a lead belonging to another company' do
      foreign = create(:lead, company: create(:company, use_rbac_system: false))

      clone_it(foreign)

      expect(response).to have_http_status(:not_found)
      expect(Lead.where(email: foreign.email).count).to eq(1)
    end

    it 'requires authentication' do
      post "/api/crm/leads/#{original.id}/clone"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # The whole point of keeping three explicit lists. Someone adding a column
  # months from now has to decide which side it falls on, instead of it being
  # copied by default and surfacing as a wrong number on a real record.
  it 'classifies every column on the table' do
    described = Api::Crm::LeadsController::CLONED_ATTRIBUTES +
                Api::Crm::LeadsController::DERIVED_ON_CLONE +
                Api::Crm::LeadsController::RESET_ON_CLONE

    expect(Lead.column_names - described).to be_empty,
                                            "unclassified lead columns: #{(Lead.column_names - described).join(', ')}"
    expect(described - Lead.column_names).to be_empty,
                                            "columns listed that do not exist: #{(described - Lead.column_names).join(', ')}"
  end
end
