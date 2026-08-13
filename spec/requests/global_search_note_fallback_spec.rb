# frozen_string_literal: true

require 'rails_helper'

# An inbound Facebook/Zapier inquiry that dedupes to an existing record is
# recorded as a NOTE on that record — the inquirer's own name never becomes a
# column on anything. Searching for that person returned nothing at all, which
# reads as "the lead was lost" when it was actually absorbed into a record the
# dealer already had.
#
# The fallback runs only when a type matched nothing by name/email/phone, so a
# normal search is unchanged and a word that appears in every inbound note
# ("Facebook") can never crowd out real name matches.
RSpec.describe 'Global search notes fallback', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "search-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Reid', last_name: 'Tester')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  def search(query)
    get '/api/v1/search/global', params: { query: query }, headers: headers
    JSON.parse(response.body)
  end

  def rows_of_type(body, type)
    body['results'].select { |r| r['type'] == type }
  end

  describe 'a lead that absorbed someone else\'s inquiry' do
    let!(:absorbing_lead) do
      create(:lead, company: company, first_name: 'Bob', last_name: 'Smith',
                    phone: '3035551212',
                    notes: "[2026-08-13 09:00 MDT] Repeat inquiry via Facebook Leads\nName: Tia May")
    end

    it 'is findable by the name in its notes' do
      rows = rows_of_type(search('Tia May'), 'lead')
      expect(rows.map { |r| r['id'] }).to eq([absorbing_lead.id])
    end

    it 'says why it matched' do
      row = rows_of_type(search('Tia May'), 'lead').first
      expect(row['matchedVia']).to eq('note')
      expect(row['subtitle']).to eq('Mentioned in notes')
      expect(row['title']).to eq('Bob Smith')
    end

    it 'finds it through a Notes-tab entry too' do
      other = create(:lead, company: company, first_name: 'Dana', last_name: 'Reyes')
      Note.create!(entity_type: 'lead', entity_id: other.id.to_s,
                   content: "🔁 REPEAT INQUIRY via Facebook Leads\n\nName: Marisol Vega")

      expect(rows_of_type(search('Marisol Vega'), 'lead').map { |r| r['id'] }).to eq([other.id])
    end

    it 'never displaces a real name match' do
      real = create(:lead, company: company, first_name: 'Tia', last_name: 'May')

      rows = rows_of_type(search('Tia May'), 'lead')
      expect(rows.map { |r| r['id'] }).to eq([real.id])
      expect(rows.first['matchedVia']).to be_nil
    end

    it 'does not leak across companies' do
      other_company_user = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                                        password: 'Password123!', company: create(:company, use_rbac_system: false),
                                        first_name: 'Other', last_name: 'Tester')
      get '/api/v1/search/global', params: { query: 'Tia May' },
                                   headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: other_company_user.id, company_id: other_company_user.company_id)}" }

      expect(rows_of_type(JSON.parse(response.body), 'lead')).to be_empty
    end
  end

  describe 'a contact that absorbed an inquiry' do
    let!(:contact) do
      Contact.create!(company_id: company.id, first_name: 'Bob', last_name: 'Smith',
                      email: 'shared@example.com',
                      notes: "[2026-08-13 09:00 MDT] Repeat inquiry via Facebook Leads\nName: Tia May")
    end

    it 'is findable by the name in its notes' do
      rows = rows_of_type(search('Tia May'), 'contact')
      expect(rows.map { |r| r['id'] }).to eq([contact.id])
      expect(rows.first['matchedVia']).to eq('note')
    end
  end
end
