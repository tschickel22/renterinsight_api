# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Leads tag column and filter', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "tags-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ada', last_name: 'Reyes')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  def tag!(name)
    Tag.create!(name: name, color: '#6B7280', is_active: true, created_by: 'spec')
  end

  def assign!(lead, tag)
    TagAssignment.create!(tag_id: tag.id, entity_type: 'Lead', entity_id: lead.id,
                          assigned_by: 'spec', assigned_at: Time.current, company_id: company.id)
  end

  let!(:hot)      { tag!('Hot') }
  let!(:financed) { tag!('Financed') }

  let!(:tagged)   { create(:lead, company: company, first_name: 'Tina',  last_name: 'Tagged') }
  let!(:both)     { create(:lead, company: company, first_name: 'Bo',    last_name: 'Both') }
  let!(:untagged) { create(:lead, company: company, first_name: 'Ursula', last_name: 'Untagged') }

  before do
    assign!(tagged, hot)
    assign!(both, hot)
    assign!(both, financed)
  end

  def ids_from(response)
    JSON.parse(response.body)['leads'].map { |l| l['id'].to_i }
  end

  it 'returns each lead with its tags so the list can show a Tags column' do
    get '/api/crm/leads', headers: headers

    row = JSON.parse(response.body)['leads'].find { |l| l['id'].to_i == both.id }
    expect(row['tags'].map { |t| t['name'] }).to match_array(%w[Hot Financed])
    expect(row['tags'].first).to include('id', 'name', 'color')
  end

  it 'filters to leads carrying the tag' do
    get '/api/crm/leads', params: { tag_ids: [hot.id] }, headers: headers

    expect(ids_from(response)).to match_array([tagged.id, both.id])
  end

  it 'matches any of several tags rather than all of them' do
    get '/api/crm/leads', params: { tag_ids: [financed.id] }, headers: headers
    expect(ids_from(response)).to eq([both.id])

    get '/api/crm/leads', params: { tag_ids: [hot.id, financed.id] }, headers: headers
    expect(ids_from(response)).to match_array([tagged.id, both.id])
  end

  it 'accepts a comma separated list, which is how the query string arrives' do
    get '/api/crm/leads', params: { tag_ids: "#{hot.id},#{financed.id}" }, headers: headers

    expect(ids_from(response)).to match_array([tagged.id, both.id])
  end

  # A join would return `both` twice, inflating the count that drives pagination
  # and the "select all matching" bulk actions.
  it 'counts a lead once even when it carries two of the selected tags' do
    get '/api/crm/leads', params: { tag_ids: [hot.id, financed.id] }, headers: headers

    body = JSON.parse(response.body)
    expect(body['leads'].map { |l| l['id'] }.uniq.size).to eq(body['leads'].size)
    expect(body['meta']['total']).to eq(2)
  end

  it 'ignores a blank or junk tag filter rather than returning nothing' do
    get '/api/crm/leads', params: { tag_ids: '' }, headers: headers

    expect(ids_from(response)).to include(tagged.id, both.id, untagged.id)
  end
end
