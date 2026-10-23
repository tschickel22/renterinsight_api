# frozen_string_literal: true

require 'rails_helper'

# Followers (backlog E86): set, notified, filtered on and visible.
RSpec.describe 'Record followers', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}") }

  def make_user(first, co = company, role: 'sales_rep')
    User.create!(email: "#{first.downcase}-#{SecureRandom.hex(3)}@example.com", first_name: first, last_name: 'Rep',
                 password: 'Pass1234!', company_id: co.id, role: role, status: 'active')
  end

  let(:admin) { make_user('Admin', role: 'platform_admin') }
  let(:owner) { make_user('Olive') }
  let(:kevin) { make_user('Kevin') }
  let(:cj)    { make_user('Cj') }

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  def lead(attrs = {})
    Lead.create!({ company_id: company.id, first_name: 'Pat', last_name: 'Buyer', status: 'new',
                   email: "l-#{SecureRandom.hex(4)}@x.com" }.merge(attrs))
  end

  def json = JSON.parse(response.body)

  let(:stage_keys) { company.pipeline_stages.map { |st| st['key'] || st[:key] } }
  let(:buyer) { Account.create!(company_id: company.id, name: "Buyer #{SecureRandom.hex(2)}") }

  def deal(attrs = {})
    Deal.create!({ company_id: company.id, name: 'Smith home', stage: stage_keys.first, account_id: buyer.id }.merge(attrs))
  end

  describe 'PUT /api/v1/followers' do
    let!(:record) { lead(owner_id: owner.id) }

    it 'replaces the set, drops the owner and other companies, and tells only new followers' do
      record.add_followers!([cj.id])
      outsider = make_user('Outsider', other_company)

      expect do
        put '/api/v1/followers', headers: headers_for(admin), as: :json,
                                 params: { record_type: 'lead', record_id: record.id,
                                           user_ids: [kevin.id, cj.id, owner.id, outsider.id] }
      end.to change { Notification.where(notification_type: 'follower_added').count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(json['followers'].map { |f| f['id'] }).to contain_exactly(kevin.id, cj.id)
      expect(Notification.where(notification_type: 'follower_added').last.recipient_id).to eq(kevin.id)

      put '/api/v1/followers', headers: headers_for(admin), as: :json,
                               params: { record_type: 'lead', record_id: record.id, user_ids: [] }
      expect(record.reload.followers).to be_empty
    end

    it 'shows followers on the record JSON' do
      record.add_followers!([kevin.id])
      get "/api/crm/leads/#{record.id}", headers: headers_for(admin)
      expect(json['followers']).to eq([{ 'id' => kevin.id, 'name' => kevin.name }])
    end

    it 'rejects an unknown record type' do
      get '/api/v1/followers', headers: headers_for(admin), params: { record_type: 'vehicle', record_id: 1 }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'list filters' do
    let!(:owned_by_kevin) { lead(owner_id: kevin.id) }
    let!(:owned_by_cj)    { lead(owner_id: cj.id) }
    let!(:followed)       { lead(owner_id: owner.id).tap { |l| l.add_followers!([kevin.id, cj.id]) } }
    let!(:unassigned)     { lead(owner_id: nil, status: 'contacted') }

    # Reps have no role permissions in this spec; the filters are what is tested.
    before { allow_any_instance_of(ApplicationController).to receive(:authorize_action!).and_return(true) }

    def ids(params, user = admin)
      get '/api/crm/leads', params: params.merge(per_page: 200), headers: headers_for(user)
      json['leads'].map { |l| l['id'] }
    end

    it 'takes several owners and unassigned' do
      expect(ids(owner_ids: "#{kevin.id},unassigned")).to contain_exactly(owned_by_kevin.id, unassigned.id)
    end

    it 'still takes the single owner_id' do
      expect(ids(owner_id: cj.id)).to contain_exactly(owned_by_cj.id)
    end

    it 'filters by follower without counting a record twice' do
      get '/api/crm/leads', params: { follower_ids: "#{kevin.id},#{cj.id}" }, headers: headers_for(admin)
      expect(json.dig('meta', 'total')).to eq(1)
    end

    it 'mine is owned or followed' do
      expect(ids({ mine: 'true' }, kevin).sort).to eq([owned_by_kevin.id, followed.id].sort)
    end

    it 'takes several statuses' do
      expect(ids(status: 'new,contacted').size).to eq(4)
      expect(ids(status: 'contacted')).to eq([unassigned.id])
    end

    it '"select all matching" bulk actions honour the same filters' do
      post '/api/crm/leads/bulk_reassign', headers: headers_for(admin), as: :json,
                                           params: { assign_to_user_id: cj.id, filter: { follower_ids: kevin.id.to_s } }
      expect(json['updated_count']).to eq(1)
      expect(followed.reload.owner_id).to eq(cj.id)
      expect(owned_by_kevin.reload.owner_id).to eq(kevin.id)

      followed_contact = Contact.create!(company_id: company.id, first_name: 'Sam', last_name: 'Smith', owner_id: owner.id)
      followed_contact.add_followers!([kevin.id])
      other_contact = Contact.create!(company_id: company.id, first_name: 'Al', last_name: 'Other', owner_id: cj.id)
      post '/api/v1/contacts/bulk_add_tags', headers: headers_for(admin), as: :json,
                                             params: { tag_names: ['Hot'], filter: { follower_ids: kevin.id.to_s } }
      expect(followed_contact.reload.tags.map(&:name)).to eq(['Hot'])
      expect(other_contact.reload.tags).to be_empty
    end

    it 'filters accounts, contacts and deals the same way' do
      account = Account.create!(company_id: company.id, name: 'Smith Family', owner_id: owner.id)
      account.add_followers!([kevin.id])
      Account.create!(company_id: company.id, name: 'Other Family', owner_id: cj.id)
      get '/api/v1/accounts', params: { follower_ids: kevin.id.to_s }, headers: headers_for(admin)
      expect(json['accounts'].map { |a| a['id'] }).to eq([account.id])
      expect(json['accounts'].first['followers']).to eq([{ 'id' => kevin.id, 'name' => kevin.name }])

      contact = Contact.create!(company_id: company.id, first_name: 'Sam', last_name: 'Smith', owner_id: owner.id)
      contact.add_followers!([kevin.id])
      get '/api/v1/contacts', params: { mine: 'true' }, headers: headers_for(kevin)
      expect(json['items'].map { |c| c['id'] }).to include(contact.id)

      deal = deal(owner_id: owner.id)
      deal.add_followers!([kevin.id])
      deal(name: 'Other home', owner_id: cj.id)
      get '/api/crm/deals', params: { follower_ids: kevin.id.to_s, view: 'all' }, headers: headers_for(admin)
      expect(json['deals'].map { |d| d['id'] }).to eq([deal.id])
    end
  end

  describe 'a location-restricted rep' do
    let(:here)  { Location.create!(company_id: company.id, name: 'Here') }
    let(:there) { Location.create!(company_id: company.id, name: 'There') }
    let!(:local)   { lead(location_id: here.id) }
    let!(:faraway) { lead(location_id: there.id) }
    let!(:hidden)  { lead(location_id: there.id) }

    before do
      faraway.add_followers!([kevin.id])
      allow_any_instance_of(ApplicationController).to receive(:authorize_action!).and_return(true)
      allow_any_instance_of(User).to receive(:uses_rbac?).and_return(true)
      allow_any_instance_of(User).to receive(:effective_admin?).and_return(false)
      allow_any_instance_of(PermissionService).to receive(:can?).and_return(false)
      allow_any_instance_of(PermissionService).to receive(:accessible_location_ids).and_return([here.id])
    end

    it 'sees what they follow outside their locations, and nothing else there' do
      get '/api/crm/leads', params: { per_page: 200 }, headers: headers_for(kevin)
      listed = json['leads'].map { |l| l['id'] }
      expect(listed).to contain_exactly(local.id, faraway.id)

      get "/api/crm/leads/#{faraway.id}", headers: headers_for(kevin)
      expect(response).to have_http_status(:ok)
      get "/api/crm/leads/#{hidden.id}", headers: headers_for(kevin)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'notifications' do
    it 'tells the owner and followers about a deal stage move, not the person who moved it' do
      deal = deal(owner_id: owner.id)
      deal.add_followers!([kevin.id, cj.id])
      Current.user = cj
      expect { deal.update!(stage: stage_keys.second) }
        .to change { Notification.where(notification_type: 'deal_stage_changed').pluck(:recipient_id).sort }
        .from([]).to([owner.id, kevin.id].sort)
    ensure
      Current.user = nil
    end

    it 'tells followers when a lead is reassigned' do
      record = lead(owner_id: owner.id)
      record.add_followers!([kevin.id])
      record.update!(owner_id: cj.id)
      expect(Notification.where(notification_type: 'followed_record_assigned').pluck(:recipient_id)).to eq([kevin.id])
    end

    it 'sends email reply notices to followers too' do
      record = lead(owner_id: owner.id)
      record.add_followers!([kevin.id])
      reply = Communication.create!(company_id: company.id, communicable: record, channel: 'email',
                                    direction: 'inbound', from_address: record.email, to_address: 'rep@dealer.test',
                                    subject: 'Re: hi', body: 'Yes')
      InboundEmail::ReplyNotifier.notify(entity: record, communication: reply)
      expect(Notification.where(notification_type: 'email_reply_received').pluck(:recipient_id))
        .to contain_exactly(owner.id, kevin.id)
    end
  end

  describe 'lead conversion' do
    it 'carries followers to the account, contact and deal' do
      record = lead(owner_id: owner.id, phone: '3035550100')
      record.add_followers!([kevin.id])
      post "/api/crm/leads/#{record.id}/convert", headers: headers_for(admin), as: :json,
                                                  params: { account_name: 'Buyer Family', create_contact: true,
                                                            create_deal: { name: 'Buyer home', value: 100_000 } }
      expect(response).to have_http_status(:ok).or have_http_status(:created)
      account = company.accounts.find(json.dig('account', 'id'))
      expect(account.followers).to eq([kevin])
      expect(company.contacts.where(account_id: account.id).flat_map(&:followers)).to include(kevin)
      expect(company.deals.where(account_id: account.id).flat_map(&:followers)).to include(kevin)
    end
  end
end
