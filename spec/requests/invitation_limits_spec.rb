# frozen_string_literal: true

require 'rails_helper'

# An invitation hands out a role and sets a password, so it needs the same limits
# as Add User and must not reverse a Disable.
RSpec.describe 'Invitation limits', type: :request do
  let(:company) { create(:company) }
  let!(:admin) { make_user('company_admin') }
  let(:manager) { make_user('company_manager') }

  def make_user(role, **attrs)
    User.create!({ email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Pass1234!',
                   company_id: company.id, role: role, status: 'active' }.merge(attrs))
  end

  def auth(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }

  def invite(user, **body)
    post "/api/companies/#{company.id}/invitations",
         params: { email: "new-#{SecureRandom.hex(3)}@example.com", recipient_name: 'New Person', role: 'read_only' }.merge(body),
         headers: auth(user)
  end

  before { allow_any_instance_of(ApplicationController).to receive(:authorize_action!).and_return(true) }

  it 'refuses a role at or above the sender' do
    invite(manager, role: 'company_admin')
    expect(response).to have_http_status(:forbidden)
    invite(manager, role: 'company_manager')
    expect(response).to have_http_status(:forbidden)
    expect(Invitation.where(company_id: company.id).count).to eq(0)
  end

  it 'lets a company admin make another company admin, and nothing higher' do
    invite(admin, role: 'company_admin')
    expect(response).to have_http_status(:created)
    invite(admin, role: 'platform_admin')
    expect(response).to have_http_status(:forbidden)
  end

  it 'lists Company Administrator for a company admin but not for a manager' do
    Role.find_or_create_by!(key: 'company_admin') { |r| r.assign_attributes(tier: 'company', name: 'Company Administrator', active: true) }
    get "/api/companies/#{company.id}/users/available-roles", headers: auth(admin)
    expect(response.parsed_body['roles'].map { |r| r['key'] }).to include('company_admin')
    get "/api/companies/#{company.id}/users/available-roles", headers: auth(manager)
    expect(response.parsed_body['roles'].map { |r| r['key'] }).not_to include('company_admin')
  end

  it 'allows a role below the sender' do
    invite(manager, role: 'sales_rep')
    expect(response).to have_http_status(:created)
  end

  it 'only lets the platform team invite a new tenant' do
    invite(admin, invitation_type: 'tenant', role: 'read_only')
    expect(response).to have_http_status(:forbidden)
  end

  it 'ignores permissions sent by a dealer' do
    invite(admin, role: 'sales_rep', permissions: ['users:delete'])
    expect(response).to have_http_status(:created)
    expect(Invitation.where(company_id: company.id).last.permissions).to be_blank
  end

  describe 'a disabled person' do
    let!(:target) { make_user('company_staff', status: 'disabled') }

    it 'cannot be resent an invitation' do
      post "/api/companies/#{company.id}/users/#{target.id}/resend_invitation", headers: auth(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'is left out of send to all pending' do
      get "/api/companies/#{company.id}/users/pending-invitations", headers: auth(admin)
      expect(response.body).not_to include(target.email)
    end

    it 'stays disabled when an old invitation is accepted' do
      invitation = Invitation.new(company_id: company.id, invited_by_id: admin.id, invitation_type: 'company_user',
                                  email: target.email, role: 'company_staff', delivery_method: 'email',
                                  token_digest: Digest::SHA256.hexdigest('old-token'), expires_at: 1.day.from_now)
      invitation.save!(validate: false)
      result = InvitationService.new(invited_by: admin, company: company)
                                .accept_invitation(token: 'old-token', user_params: { first_name: 'A', last_name: 'B', password: 'Newpass123!' })
      expect(result[:success]).to be(false)
      expect(target.reload.status).to eq('disabled')
    end
  end
end
