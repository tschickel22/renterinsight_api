# frozen_string_literal: true

require 'rails_helper'

# E68 step 5a: one sign-in for several companies. A linked account is an
# ordinary user in one company that points at the person's sign-in account;
# the person signs in once and switches.
RSpec.describe 'Linked accounts', type: :request do
  let(:dealer_co) { create(:company, name: 'Summit Homes') }
  let(:installer_co) { create(:company, name: 'Summit Install') }
  let(:other_co) { create(:company, name: 'Someone Else') }

  let(:person) do
    User.create!(email: 'pat@summit.example', first_name: 'Pat', last_name: 'Lee', password: 'Pass1234!',
                 company_id: dealer_co.id, role: 'company_admin', status: 'active')
  end
  let(:installer_admin) do
    User.create!(email: 'boss@install.example', first_name: 'Boss', last_name: 'Install', password: 'Pass1234!',
                 company_id: installer_co.id, role: 'company_admin', status: 'active')
  end

  def body = JSON.parse(response.body)

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}", 'Content-Type' => 'application/json' }
  end

  def link(user, company, role: 'staff')
    User.create!(email: user.email, primary_user: user, company_id: company.id, first_name: user.first_name,
                 last_name: user.last_name, role: role, status: 'active', password: SecureRandom.hex(16))
  end

  describe 'the linked account' do
    it 'shares the email, one per company, and never with a platform admin' do
      linked = link(person, installer_co)
      expect(linked).to be_linked_account
      expect(linked.sign_in_account).to eq(person)

      expect { link(person, installer_co) }.to raise_error(ActiveRecord::RecordInvalid, /Email/)
      expect { link(person, dealer_co) }.to raise_error(ActiveRecord::RecordInvalid, /different company/)
      expect { link(linked, other_co) }.to raise_error(ActiveRecord::RecordInvalid, /sign-in account/)

      admin = User.create!(email: 'ops@platform.example', first_name: 'O', last_name: 'P', password: 'Pass1234!', role: 'platform_admin', status: 'active')
      expect { link(admin, installer_co) }.to raise_error(ActiveRecord::RecordInvalid, /platform admins/)

      # A second sign-in account with the same email is still refused.
      expect { User.create!(email: 'PAT@summit.example', first_name: 'X', password: 'Pass1234!', company_id: other_co.id, status: 'active') }
        .to raise_error(ActiveRecord::RecordInvalid, /Email/)
    end
  end

  describe 'signing in and switching' do
    let!(:linked) { link(person, installer_co) }

    it 'signs in to the sign-in account, never the linked one' do
      post '/api/auth/login', params: { email: person.email, password: 'Pass1234!' }.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:ok)
      expect(body.dig('user', 'id')).to eq(person.id)
    end

    it 'lists both companies and switches to the installer' do
      get '/api/auth/accounts', headers: headers_for(person)
      expect(body['accounts'].map { |a| a['company_name'] }).to eq(['Summit Homes', 'Summit Install'])

      post '/api/auth/switch_account', params: { user_id: linked.id }.to_json, headers: headers_for(person)
      expect(response).to have_http_status(:ok)
      expect(body.dig('user', 'id')).to eq(linked.id)
      expect(body.dig('user', 'company_id')).to eq(installer_co.id)
      expect(JsonWebToken.decode(body['token'])[:company_id]).to eq(installer_co.id)

      # And back again from the linked account.
      post '/api/auth/switch_account', params: { user_id: person.id }.to_json, headers: headers_for(linked)
      expect(body.dig('user', 'company_id')).to eq(dealer_co.id)
    end

    it "refuses an account that isn't the person's own" do
      stranger = User.create!(email: 'x@else.example', first_name: 'X', password: 'Pass1234!', company_id: other_co.id, status: 'active')
      post '/api/auth/switch_account', params: { user_id: stranger.id }.to_json, headers: headers_for(person)
      expect(response).to have_http_status(:not_found)
    end

    it "drops a company once that company deactivates the person, and refuses the old token" do
      token_headers = headers_for(linked)
      linked.update!(status: 'inactive')

      get '/api/auth/accounts', headers: headers_for(person)
      expect(body['accounts'].map { |a| a['company_name'] }).to eq(['Summit Homes'])

      get '/api/auth/accounts', headers: token_headers
      expect(response).to have_http_status(:unauthorized)
      expect(body['code']).to eq('user_inactive')
    end

    it 'checks and changes the password on the sign-in account' do
      post '/api/auth/verify_password', params: { password: 'Pass1234!' }.to_json, headers: headers_for(linked)
      expect(body['valid']).to be(true)
    end
  end

  describe 'inviting someone who already signs in elsewhere' do
    let(:service) { InvitationService.new(invited_by: installer_admin, company: installer_co) }

    def invite(email = person.email)
      result = service.create_invitation(invitation_type: 'company_user', email: email, role: 'staff', skip_send: true)
      expect(result[:success]).to be(true), result[:error].to_s
      result[:invitation]
    end

    it 'makes an invited linked account and leaves their own account alone' do
      digest = person.password_digest
      invitation = invite

      placeholder = installer_co.users.find_by(email: person.email)
      expect(placeholder.primary_user).to eq(person)
      expect(placeholder.status).to eq('invited')
      expect(person.reload.user_role_assignments.where(company_id: installer_co.id)).to be_empty
      expect(invitation.existing_account?).to be(true)

      get '/api/public/invitations/verify', params: { token: invitation.token }
      expect(body['existingAccount']).to be(true)

      post "/api/public/invitations/accept?token=#{invitation.token}", params: { password: 'wrong' }.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(body['success']).to be(false)

      post "/api/public/invitations/accept?token=#{invitation.token}", params: { password: 'Pass1234!' }.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(body['success']).to be(true)
      expect(body['token']).to be_nil
      expect(placeholder.reload.status).to eq('active')
      expect(person.reload.password_digest).to eq(digest)
      expect(person.company_accounts.map(&:company_id)).to eq([dealer_co.id, installer_co.id])
    end

    it 'never returns the other company user from the invite endpoint' do
      person
      post "/api/companies/#{installer_co.id}/users",
           params: { email: person.email, role: 'staff', first_name: 'Pat', last_name: 'Lee' }.to_json,
           headers: headers_for(installer_admin)
      expect(response).to have_http_status(:created), response.body
      expect(body.dig('user', 'id')).not_to eq(person.id)
    end

    it "won't add a platform admin to a company" do
      User.create!(email: 'ops@platform.example', first_name: 'O', last_name: 'P', password: 'Pass1234!', role: 'platform_admin', status: 'active', company_id: other_co.id)
      result = service.create_invitation(invitation_type: 'company_user', email: 'ops@platform.example', role: 'staff', skip_send: true)
      expect(result[:success]).to be(false)
    end
  end
end
