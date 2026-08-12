# frozen_string_literal: true

require 'rails_helper'

# Two ways global search told a user a record did not exist when it did.
#
# Searching an email address returned nothing for any lead marked lost,
# unqualified or dead. That is 14% of the largest tenant's leads, and it is the
# cohort you most often search for, because the question being asked is "have we
# dealt with this person before?".
#
# And a first name is not a distinguishing match. A dealer with 3,000 leads has
# a dozen people called Brad, every one of them ranked identically, and only
# five came back ordered by id. The one being looked for was ninth and never
# appeared until enough of the surname was typed to narrow the set.
RSpec.describe 'Global search reachability', type: :request do
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

  def lead_ids(body)
    body['results'].select { |r| r['type'] == 'lead' }.map { |r| r['id'] }
  end

  describe 'a lead whose status is a dead end' do
    let!(:lost) do
      create(:lead, company: company, first_name: 'Brad', last_name: 'Sanders',
                    email: 'brad@oalodgemhc.com', status: 'lost')
    end

    it 'is still findable by email address' do
      expect(lead_ids(search('brad@oalodgemhc.com'))).to include(lost.id)
    end

    it 'is still findable by name' do
      expect(lead_ids(search('sanders'))).to include(lost.id)
    end

    it 'carries its status so the result reads as dead' do
      row = search('brad@oalodgemhc.com')['results'].find { |r| r['id'] == lost.id }
      expect(row['badge']).to eq('Lost')
    end

    it 'is findable on a partial email fragment' do
      expect(lead_ids(search('oalodgemhc'))).to include(lost.id)
    end

    # Every dead-end status the old filter hid, checked by the thing a rep
    # actually types: the address off an email they are holding.
    %w[lost unqualified dead junk_lead closed_lost].each do |dead_end|
      it "finds a '#{dead_end}' lead by its email address" do
        buried = create(:lead, company: company, first_name: 'Buried', last_name: dead_end.camelize,
                               email: "#{dead_end}@example.com", status: dead_end)

        expect(lead_ids(search("#{dead_end}@example.com"))).to include(buried.id)
      end
    end
  end

  describe 'a converted lead' do
    it 'stays out, because it is reachable as the contact it became' do
      converted = create(:lead, company: company, first_name: 'Gone', last_name: 'Converted',
                                email: 'gone@example.com', is_converted: true)

      expect(lead_ids(search('gone@example.com'))).not_to include(converted.id)
    end
  end

  describe 'a first name shared by many leads' do
    let!(:brads) do
      # Named so none of them matches on the surname, and created oldest-first so
      # the one we want is NOT the newest by id.
      12.times.map do |i|
        create(:lead, company: company, first_name: 'Brad', last_name: "Other#{i}",
                      email: "brad#{i}@example.com", status: 'open')
      end
    end
    let!(:wanted) do
      create(:lead, company: company, first_name: 'Brad', last_name: 'Sanders',
                    email: 'brad@oalodgemhc.com', status: 'open',
                    last_activity_at: Time.current)
    end

    it 'surfaces the most recently active one rather than the most recently created' do
      expect(lead_ids(search('brad'))).to include(wanted.id)
    end

    it 'reports how many there really are, so the caller can say 10 of N' do
      body = search('brad')

      expect(body['results'].count { |r| r['type'] == 'lead' })
        .to eq(Api::V1::SearchController::PER_TYPE_LIMIT)
      expect(body['totals']['lead']).to eq(13)
    end

    it 'counts nothing for a type that fits inside the limit' do
      expect(search('oalodgemhc')['totals']).to eq({})
    end

    it 'returns the rest when the caller asks for more' do
      get '/api/v1/search/global', params: { query: 'brad', limit: 50 }, headers: headers
      body = JSON.parse(response.body)

      expect(body['results'].count { |r| r['type'] == 'lead' }).to eq(13)
      expect(lead_ids(body)).to include(wanted.id)
    end

    it 'refuses to be talked into returning the whole table' do
      get '/api/v1/search/global', params: { query: 'brad', limit: 99_999 }, headers: headers

      expect(JSON.parse(response.body)['limit'])
        .to eq(Api::V1::SearchController::MAX_PER_TYPE_LIMIT)
    end
  end
end
