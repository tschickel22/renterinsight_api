# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::Portal::AuthController, type: :controller do
  let(:lead) { create(:lead, email: 'buyer@example.com', first_name: 'John', last_name: 'Doe') }
  let(:buyer_access) do
    create(:buyer_portal_access,
           buyer: lead,
           email: 'buyer@example.com',
           password: 'Password123!',
           portal_enabled: true)
  end

  before do
    # Clear cache before each test
    Rails.cache.clear
  end

  describe 'POST #login' do
    context 'with valid credentials' do
      it 'returns a JWT token and buyer profile' do
        post :login, params: { email: buyer_access.email, password: 'Password123!' }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['ok']).to be true
        expect(json['token']).to be_present
        expect(json['buyer']['email']).to eq(buyer_access.email)
      end

      it 'records the login' do
        expect do
          post :login, params: { email: buyer_access.email, password: 'Password123!' }
          buyer_access.reload
        end.to change { buyer_access.login_count }.by(1)
      end

      it 'handles case-insensitive email' do
        # Create a fresh buyer with lowercase email
        lead2 = create(:lead, email: 'testbuyer@example.com')
        buyer2 = create(:buyer_portal_access, 
                       buyer: lead2, 
                       email: 'testbuyer@example.com',
                       password: 'Password123!')
        
        post :login, params: { email: 'TESTBUYER@EXAMPLE.COM', password: 'Password123!' }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['ok']).to be true
      end
    end

    context 'with invalid credentials' do
      it 'returns unauthorized for wrong password' do
        post :login, params: { email: buyer_access.email, password: 'WrongPassword' }

        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
        expect(json['error']).to eq('Invalid email or password')
      end

      it 'returns unauthorized for non-existent email' do
        post :login, params: { email: 'nonexistent@example.com', password: 'Password123!' }

        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
      end
    end

    context 'when portal is disabled' do
      before { buyer_access.update!(portal_enabled: false) }

      it 'returns unauthorized' do
        post :login, params: { email: buyer_access.email, password: 'Password123!' }

        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
      end
    end

    context 'rate limiting' do
      it 'blocks after 5 attempts', :skip do
        # Set the same IP for all requests
        @request.env['REMOTE_ADDR'] = '192.168.1.100'
        
        # Make 5 failed attempts
        6.times do
          post :login, params: { email: 'test@example.com', password: 'wrong' }
          expect(response).to have_http_status(:unauthorized)
        end

        # 6th attempt should be rate limited
        post :login, params: { email: 'test@example.com', password: 'wrong' }

        expect(response).to have_http_status(:too_many_requests)
        json = JSON.parse(response.body)
        expect(json['error']).to include('Too many attempts')
      end
    end
  end

  describe 'POST #request_magic_link' do
    before { allow(BuyerPortalService).to receive(:send_magic_link_email) }

    context 'with valid email' do
      it 'generates a login token' do
        expect do
          post :request_magic_link, params: { email: buyer_access.email }
          buyer_access.reload
        end.to change { buyer_access.login_token }.from(nil)
      end

      it 'sends a magic link email' do
        post :request_magic_link, params: { email: buyer_access.email }
        expect(BuyerPortalService).to have_received(:send_magic_link_email).with(buyer_access)
      end

      it 'returns success message' do
        post :request_magic_link, params: { email: buyer_access.email }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['ok']).to be true
        expect(json['message']).to be_present
      end
    end

    context 'with non-existent email' do
      it 'returns success message (security)' do
        post :request_magic_link, params: { email: 'nonexistent@example.com' }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['ok']).to be true
      end

      it 'does not send email' do
        post :request_magic_link, params: { email: 'nonexistent@example.com' }
        expect(BuyerPortalService).not_to have_received(:send_magic_link_email)
      end
    end

    context 'when portal is disabled' do
      before { buyer_access.update!(portal_enabled: false) }

      it 'returns success but does not send email' do
        post :request_magic_link, params: { email: buyer_access.email }

        expect(response).to have_http_status(:ok)
        expect(BuyerPortalService).not_to have_received(:send_magic_link_email)
      end
    end
  end

  describe 'GET #verify_magic_link' do
    before { buyer_access.generate_login_token }

    context 'with valid token' do
      it 'returns a JWT token' do
        get :verify_magic_link, params: { token: buyer_access.login_token }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['ok']).to be true
        expect(json['token']).to be_present
      end

      it 'records the login' do
        expect do
          get :verify_magic_link, params: { token: buyer_access.login_token }
          buyer_access.reload
        end.to change { buyer_access.login_count }.by(1)
      end

      it 'clears the login token' do
        get :verify_magic_link, params: { token: buyer_access.login_token }
        buyer_access.reload

        expect(buyer_access.login_token).to be_nil
        expect(buyer_access.login_token_expires_at).to be_nil
      end
    end

    context 'with expired token' do
      before { buyer_access.update!(login_token_expires_at: 16.minutes.ago) }

      it 'returns unauthorized' do
        get :verify_magic_link, params: { token: buyer_access.login_token }

        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
        expect(json['error']).to include('Invalid or expired')
      end
    end

    context 'with invalid token' do
      it 'returns unauthorized' do
        get :verify_magic_link, params: { token: 'invalid-token' }

        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
      end
    end
  end

  describe 'POST #request_reset' do
    before { allow(BuyerPortalService).to receive(:send_password_reset_email) }

    context 'with valid email' do
      it 'generates a reset token' do
        expect do
          post :request_reset, params: { email: buyer_access.email }
          buyer_access.reload
        end.to change { buyer_access.reset_token }.from(nil)
      end

      it 'sends a password reset email' do
        post :request_reset, params: { email: buyer_access.email }
        expect(BuyerPortalService).to have_received(:send_password_reset_email).with(buyer_access)
      end

      it 'returns success message' do
        post :request_reset, params: { email: buyer_access.email }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['ok']).to be true
      end
    end

    context 'with non-existent email' do
      it 'returns success message (security)' do
        post :request_reset, params: { email: 'nonexistent@example.com' }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['ok']).to be true
      end
    end
  end

  describe 'PATCH #reset_password' do
    before { buyer_access.generate_reset_token }

    context 'with valid token and password' do
      let(:new_password) { 'NewPassword123!' }

      it 'updates the password' do
        patch :reset_password, params: {
          token: buyer_access.reset_token,
          password: new_password,
          password_confirmation: new_password
        }

        expect(response).to have_http_status(:ok)
        buyer_access.reload
        expect(buyer_access.authenticate(new_password)).to be_truthy
      end

      it 'clears the reset token' do
        patch :reset_password, params: {
          token: buyer_access.reset_token,
          password: new_password,
          password_confirmation: new_password
        }

        buyer_access.reload
        expect(buyer_access.reset_token).to be_nil
        expect(buyer_access.reset_token_expires_at).to be_nil
      end
    end

    context 'with mismatched passwords' do
      it 'returns unprocessable entity' do
        patch :reset_password, params: {
          token: buyer_access.reset_token,
          password: 'NewPassword123!',
          password_confirmation: 'DifferentPassword123!'
        }

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
        expect(json['errors']).to be_present
      end
    end

    context 'with expired token' do
      before { buyer_access.update!(reset_token_expires_at: 2.hours.ago) }

      it 'returns unauthorized' do
        patch :reset_password, params: {
          token: buyer_access.reset_token,
          password: 'NewPassword123!',
          password_confirmation: 'NewPassword123!'
        }

        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
      end
    end

    context 'with invalid token' do
      it 'returns unauthorized' do
        patch :reset_password, params: {
          token: 'invalid-token',
          password: 'NewPassword123!',
          password_confirmation: 'NewPassword123!'
        }

        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
      end
    end
  end

  describe 'GET #profile' do
    context 'when authenticated' do
      before do
        token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
        request.headers['Authorization'] = "Bearer #{token}"
      end

      it 'returns buyer profile' do
        get :profile

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['ok']).to be true
        expect(json['buyer']['email']).to eq(buyer_access.email)
        expect(json['buyer']['buyer_type']).to eq('Lead')
      end
    end

    context 'when not authenticated' do
      it 'returns unauthorized' do
        get :profile

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with invalid token' do
      before do
        request.headers['Authorization'] = 'Bearer invalid-token'
      end

      it 'returns unauthorized' do
        get :profile

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
