# frozen_string_literal: true

require 'rails_helper'

# Three things that were wrong on the Users screen. Edit User saved 'disabled',
# which no sign-in check knew about, so a disabled person kept working. Delete
# User destroyed the record though its dialog promised it could be reversed,
# and Restore had no action behind its route. Edit User's location change went
# to an action that never read it. None of the actions checked permission.
RSpec.describe 'Company users access', type: :request do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let!(:admin) { make_user('company_admin') }
  let!(:target) { make_user('company_staff') }
  let(:denver) { company.locations.create!(name: 'Denver') }
  let(:boise) { company.locations.create!(name: 'Boise') }

  def make_user(role, co = company, **attrs)
    User.create!({ email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Pass1234!',
                   company_id: co.id, role: role, status: 'active' }.merge(attrs))
  end

  def auth(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }

  def active_locations(user) = user.user_locations.where(active: true).pluck(:location_id)

  def assign(user, location, active: true)
    UserLocation.create!(user: user, location: location, company_id: company.id, location_role: 'location_staff', active: active)
  end

  describe 'a deactivated user' do
    %w[disabled inactive suspended].each do |status|
      it "is refused at sign-in, on refresh and on every request when #{status}" do
        token = JsonWebToken.generate_access_token(target)
        refresh = JsonWebToken.generate_token_pair(target)[:refresh_token]
        target.update!(status: status)

        post '/api/auth/login', params: { email: target.email, password: 'Pass1234!' }
        expect(response).to have_http_status(:forbidden)

        post '/api/auth/refresh', params: { refresh_token: refresh }
        expect(response.status).to be_in([401, 403])

        get '/api/crm/leads', headers: { 'Authorization' => "Bearer #{token}" }
        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body['code']).to eq('user_inactive')
      end
    end

    it 'cannot be impersonated' do
      target.update!(status: 'disabled')
      platform = User.create!(email: "p-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A', password: 'Pass1234!', role: 'platform_admin', status: 'active')
      post '/api/auth/impersonate', params: { user_id: target.id, company_id: company.id, reason: 'support' }, headers: auth(platform)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to include('inactive')
    end

    it 'leaves an invited user alone' do
      expect(make_user('company_staff', status: 'invited')).not_to be_deactivated
    end
  end

  describe 'Delete User' do
    it 'keeps the person, stops their access and hides them from the normal list' do
      assign(target, denver)
      delete "/api/companies/#{company.id}/users/#{target.id}", params: { reason: 'left' }, headers: auth(admin)

      expect(response).to have_http_status(:ok)
      target.reload
      expect(target.deleted_at).to be_present
      expect(target.status).to eq('inactive')
      expect(active_locations(target)).to eq([])

      get "/api/companies/#{company.id}/users", headers: auth(admin)
      expect(response.parsed_body['users'].map { |u| u['id'] }).not_to include(target.id)

      get "/api/companies/#{company.id}/users", params: { include_deleted: true }, headers: auth(admin)
      expect(response.parsed_body['users'].map { |u| u['id'] }).to include(target.id)
    end

    it 'restores access and the locations they had, not ones removed earlier' do
      assign(target, denver)
      assign(target, boise, active: false)
      delete "/api/companies/#{company.id}/users/#{target.id}", headers: auth(admin)

      post "/api/companies/#{company.id}/users/#{target.id}/restore", headers: auth(admin)

      expect(response).to have_http_status(:ok)
      target.reload
      expect(target.deleted_at).to be_nil
      expect(target.status).to eq('active')
      expect(active_locations(target)).to eq([denver.id])
    end

    it 'restores through the older route too' do
      target.soft_delete
      post "/api/v1/users/#{target.id}/restore", headers: auth(admin).merge('X-Company-ID' => company.id.to_s)
      expect(response).to have_http_status(:ok)
      expect(target.reload.status).to eq('active')
    end

    it 'puts someone still waiting on an invitation back to waiting' do
      invitation = Invitation.new(email: target.email, company: company, invitation_type: 'company_user', role: 'company_staff',
                                  status: 'pending', expires_at: 3.days.from_now, token_digest: SecureRandom.hex(8), invited_by_id: admin.id, delivery_method: 'email')
      invitation.save!(validate: false)
      target.update!(status: 'invited', invitation_id: invitation.id)
      target.soft_delete
      expect(target.restore_deleted).to be(true)
      expect(target.reload.status).to eq('invited')
    end

    it 'will not restore past the seat limit' do
      target.soft_delete
      company.update!(max_users: 1)
      post "/api/companies/#{company.id}/users/#{target.id}/restore", headers: auth(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(target.reload.deleted_at).to be_present
    end

    it 'refuses people without permission, yourself, higher roles and other companies' do
      staff = make_user('read_only')
      delete "/api/companies/#{company.id}/users/#{target.id}", headers: auth(staff)
      expect(response).to have_http_status(:forbidden)
      expect(target.reload.deleted_at).to be_nil

      delete "/api/companies/#{company.id}/users/#{admin.id}", headers: auth(admin)
      expect(response).to have_http_status(:forbidden)

      outsider = make_user('company_admin', other_company)
      delete "/api/companies/#{company.id}/users/#{target.id}", headers: auth(outsider)
      expect(response).to have_http_status(:forbidden)
      expect(target.reload.deleted_at).to be_nil
    end

    it 'lets one admin delete another' do
      second = make_user('company_admin')
      delete "/api/companies/#{company.id}/users/#{second.id}", headers: auth(admin)
      expect(response).to have_http_status(:ok)
    end

    it 'refuses a new invitation to a deleted email and says how to get them back' do
      target.soft_delete
      post "/api/companies/#{company.id}/users", params: { email: target.email.upcase, role: 'company_staff' }, headers: auth(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('restore')
    end
  end

  describe 'Edit User locations' do
    def put_user(user, by: admin, **extra)
      put "/api/companies/#{company.id}/users/#{user.id}", params: { user: { first_name: 'New' } }.merge(extra), headers: auth(by), as: :json
    end

    it 'saves the chosen locations and turns off the rest' do
      assign(target, boise)
      put_user(target, location_ids: [denver.id], location_role: 'location_staff')
      expect(response).to have_http_status(:ok)
      expect(active_locations(target)).to eq([denver.id])
    end

    it 'leaves them alone when the list is not sent, and clears them on an empty list' do
      assign(target, denver)
      put_user(target)
      expect(active_locations(target)).to eq([denver.id])
      put_user(target, location_ids: [])
      expect(active_locations(target)).to eq([])
    end

    it 'keeps the location role already held' do
      assign(target, denver).update!(location_role: 'location_admin')
      put_user(target, location_ids: [denver.id, boise.id], location_role: 'location_staff')
      roles = target.user_locations.where(active: true).pluck(:location_id, :location_role).to_h
      expect(roles).to eq(denver.id => 'location_admin', boise.id => 'location_staff')
    end

    it "ignores another company's location" do
      foreign = other_company.locations.create!(name: 'Elsewhere')
      put_user(target, location_ids: [foreign.id, denver.id])
      expect(active_locations(target)).to eq([denver.id])
      expect(UserLocation.where(user_id: target.id, location_id: foreign.id)).not_to exist
    end

    it 'refuses someone without permission, and changes nothing' do
      viewer = make_user('read_only')
      put_user(target, by: viewer, location_ids: [denver.id])
      expect(response).to have_http_status(:forbidden)
      expect(target.reload.first_name).to eq('U')
      expect(active_locations(target)).to eq([])
    end

    it 'refuses editing someone above you' do
      boss = make_user('company_admin')
      manager = make_user('company_manager')
      allow_any_instance_of(ApplicationController).to receive(:can?).and_return(true)
      put_user(boss, by: manager, location_ids: [denver.id])
      expect(response).to have_http_status(:forbidden)
      expect(boss.reload.first_name).to eq('U')
    end

    it 'still lets people edit their own profile' do
      put_user(target, by: target)
      expect(response).to have_http_status(:ok)
      expect(target.reload.first_name).to eq('New')
    end
  end
end
