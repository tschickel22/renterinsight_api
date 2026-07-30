# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::Portal::PreferencesController, type: :controller do
  let(:company) { Company.create!(name: 'Test Company') }
  let(:source) { Source.create!(name: 'Test Source', source_type: 'website', is_active: true) }
  let(:lead) { Lead.create!(first_name: 'Test', last_name: 'Buyer', email: 'buyer@test.com', phone: '555-1234', source: source, company: company) }
  
  let!(:portal_access) do
    BuyerPortalAccess.create!(
      buyer: lead,
      email: 'buyer@test.com',
      password: 'Password123!',
      email_opt_in: true,
      sms_opt_in: false,
      marketing_opt_in: true,
      portal_enabled: true
    )
  end

  # Portal tokens are minted by JsonWebToken (ENV['JWT_SECRET']) and carry
  # buyer_portal_access_id — the same shape Api::Portal::BaseController and the
  # real /api/portal/auth/login flow use. The previous helper signed with
  # Rails.application.secret_key_base and buyer_id/buyer_type claims, which no
  # part of the app produces.
  let(:valid_token) do
    JsonWebToken.encode({ buyer_portal_access_id: portal_access.id }, 24.hours.from_now)
  end

  let(:expired_token) do
    JsonWebToken.encode({ buyer_portal_access_id: portal_access.id }, 1.hour.ago)
  end

  let(:invalid_token) { 'invalid.token.here' }

  describe 'GET #show' do
    context 'with valid authentication' do
      before do
        request.headers['Authorization'] = "Bearer #{valid_token}"
      end

      it 'returns ok status' do
        get :show
        expect(response).to have_http_status(:ok)
      end

      it 'returns preferences in correct format' do
        get :show
        json = JSON.parse(response.body)
        
        expect(json['ok']).to eq(true)
        expect(json['preferences']).to be_present
        expect(json['preferences']['email_opt_in']).to eq(true)
        expect(json['preferences']['sms_opt_in']).to eq(false)
        expect(json['preferences']['marketing_opt_in']).to eq(true)
        expect(json['preferences']['portal_enabled']).to eq(true)
      end

      it 'returns all four preference fields' do
        get :show
        json = JSON.parse(response.body)
        
        expect(json['preferences'].keys).to contain_exactly(
          'email_opt_in', 'sms_opt_in', 'marketing_opt_in', 'portal_enabled'
        )
      end
    end

    context 'without authentication' do
      it 'returns unauthorized status' do
        get :show
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns error message' do
        get :show
        json = JSON.parse(response.body)

        # Shared portal contract (Api::Portal::BaseController), same as quotes /
        # invoices / documents / agreements.
        expect(json['error']).to eq('Missing authorization header')
      end
    end

    context 'with expired token' do
      before do
        request.headers['Authorization'] = "Bearer #{expired_token}"
      end

      it 'returns unauthorized status' do
        get :show
        expect(response).to have_http_status(:unauthorized)
      end

      # Still a 401, but the message is the generic one: JsonWebToken.decode
      # rescues JWT::ExpiredSignature internally and returns nil, so
      # BaseController's own `rescue JWT::ExpiredSignature` branch never runs and
      # an expired token falls through to the nil-payload check. That quirk is
      # shared by every portal controller, so it is asserted, not "fixed" here.
      it 'returns an invalid token error' do
        get :show
        json = JSON.parse(response.body)

        expect(json['error']).to eq('Invalid token')
      end
    end

    context 'with invalid token' do
      before do
        request.headers['Authorization'] = "Bearer #{invalid_token}"
      end

      it 'returns unauthorized status' do
        get :show
        expect(response).to have_http_status(:unauthorized)
      end
    end

    # A token naming an access record that no longer exists is rejected by
    # BaseController before the action runs, so this is a 401 rather than the
    # 404 the old bespoke auth returned. That 404 was unreachable in practice —
    # every request to this controller 401'd — so nothing depends on it.
    context 'when the portal access no longer exists' do
      let(:orphan_token) do
        JsonWebToken.encode({ buyer_portal_access_id: portal_access.id + 10_000 })
      end

      before do
        request.headers['Authorization'] = "Bearer #{orphan_token}"
      end

      it 'returns unauthorized status' do
        get :show
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns error message' do
        get :show
        json = JSON.parse(response.body)

        expect(json['error']).to eq('Portal access disabled')
      end
    end
  end

  describe 'PATCH #update' do
    context 'with valid authentication' do
      before do
        request.headers['Authorization'] = "Bearer #{valid_token}"
      end

      context 'updating email_opt_in' do
        it 'successfully updates preference' do
          patch :update, params: { preferences: { email_opt_in: false } }
          
          expect(response).to have_http_status(:ok)
          portal_access.reload
          expect(portal_access.email_opt_in).to eq(false)
        end

        it 'returns updated preferences' do
          patch :update, params: { preferences: { email_opt_in: false } }
          json = JSON.parse(response.body)
          
          expect(json['ok']).to eq(true)
          expect(json['preferences']['email_opt_in']).to eq(false)
        end

        it 'tracks change in history' do
          expect {
            patch :update, params: { preferences: { email_opt_in: false } }
          }.to change { portal_access.reload.preference_history.length }.by(1)
        end
      end

      context 'updating sms_opt_in' do
        it 'successfully updates preference' do
          patch :update, params: { preferences: { sms_opt_in: true } }
          
          expect(response).to have_http_status(:ok)
          portal_access.reload
          expect(portal_access.sms_opt_in).to eq(true)
        end
      end

      context 'updating marketing_opt_in' do
        it 'successfully updates preference' do
          patch :update, params: { preferences: { marketing_opt_in: false } }
          
          expect(response).to have_http_status(:ok)
          portal_access.reload
          expect(portal_access.marketing_opt_in).to eq(false)
        end
      end

      context 'updating multiple preferences' do
        it 'successfully updates all preferences' do
          patch :update, params: { 
            preferences: { 
              email_opt_in: false,
              sms_opt_in: true,
              marketing_opt_in: false
            } 
          }
          
          expect(response).to have_http_status(:ok)
          portal_access.reload
          expect(portal_access.email_opt_in).to eq(false)
          expect(portal_access.sms_opt_in).to eq(true)
          expect(portal_access.marketing_opt_in).to eq(false)
        end

        it 'tracks all changes in single history entry' do
          patch :update, params: { 
            preferences: { 
              email_opt_in: false,
              sms_opt_in: true
            } 
          }
          
          portal_access.reload
          last_change = portal_access.preference_history.last
          
          expect(last_change['changes']).to have_key('email_opt_in')
          expect(last_change['changes']).to have_key('sms_opt_in')
        end
      end

      context 'attempting to update portal_enabled' do
        it 'returns forbidden status' do
          patch :update, params: { preferences: { portal_enabled: false } }
          expect(response).to have_http_status(:forbidden)
        end

        it 'returns error message' do
          patch :update, params: { preferences: { portal_enabled: false } }
          json = JSON.parse(response.body)
          
          expect(json['ok']).to eq(false)
          expect(json['error']).to eq('Cannot modify portal_enabled through API')
        end

        it 'does not update portal_enabled' do
          patch :update, params: { preferences: { portal_enabled: false } }
          portal_access.reload
          expect(portal_access.portal_enabled).to eq(true)
        end

        it 'does not track change in history' do
          expect {
            patch :update, params: { preferences: { portal_enabled: false } }
          }.not_to change { portal_access.reload.preference_history.length }
        end
      end

      context 'with invalid boolean values' do
        it 'rejects non-boolean string' do
          patch :update, params: { preferences: { email_opt_in: 'yes' } }
          expect(response).to have_http_status(:unprocessable_entity)
        end

        it 'returns error message for invalid value' do
          patch :update, params: { preferences: { email_opt_in: 'invalid' } }
          json = JSON.parse(response.body)
          
          expect(json['ok']).to eq(false)
          expect(json['error']).to eq('Invalid preference values. Must be true or false.')
        end

        it 'rejects numeric values' do
          patch :update, params: { preferences: { email_opt_in: 1 } }
          expect(response).to have_http_status(:unprocessable_entity)
        end

        it 'rejects null values' do
          patch :update, params: { preferences: { email_opt_in: nil } }
          expect(response).to have_http_status(:unprocessable_entity)
        end
      end

      context 'with string boolean values' do
        it 'accepts "true" string' do
          patch :update, params: { preferences: { email_opt_in: 'true' } }
          expect(response).to have_http_status(:ok)
        end

        it 'accepts "false" string' do
          patch :update, params: { preferences: { email_opt_in: 'false' } }
          expect(response).to have_http_status(:ok)
        end
      end

      context 'with empty preferences' do
        it 'returns ok with no changes' do
          patch :update, params: { preferences: {} }
          expect(response).to have_http_status(:ok)
        end

        it 'does not add to history' do
          expect {
            patch :update, params: { preferences: {} }
          }.not_to change { portal_access.reload.preference_history.length }
        end
      end
    end

    context 'without authentication' do
      it 'returns unauthorized status' do
        patch :update, params: { preferences: { email_opt_in: false } }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'GET #history' do
    context 'with valid authentication' do
      before do
        request.headers['Authorization'] = "Bearer #{valid_token}"
      end

      context 'with no history' do
        it 'returns ok status' do
          get :history
          expect(response).to have_http_status(:ok)
        end

        it 'returns empty history array' do
          get :history
          json = JSON.parse(response.body)
          
          expect(json['ok']).to eq(true)
          expect(json['history']).to eq([])
        end
      end

      context 'with existing history' do
        before do
          # Create some history
          portal_access.update!(email_opt_in: false)
          portal_access.update!(sms_opt_in: true)
          portal_access.update!(marketing_opt_in: false)
        end

        it 'returns ok status' do
          get :history
          expect(response).to have_http_status(:ok)
        end

        it 'returns history entries' do
          get :history
          json = JSON.parse(response.body)
          
          expect(json['ok']).to eq(true)
          expect(json['history'].length).to eq(3)
        end

        it 'includes timestamp in each entry' do
          get :history
          json = JSON.parse(response.body)
          
          json['history'].each do |entry|
            expect(entry).to have_key('timestamp')
            expect(entry['timestamp']).to be_present
          end
        end

        it 'includes changes in each entry' do
          get :history
          json = JSON.parse(response.body)
          
          json['history'].each do |entry|
            expect(entry).to have_key('changes')
            expect(entry['changes']).to be_a(Hash)
          end
        end

        it 'shows from and to values in changes' do
          get :history
          json = JSON.parse(response.body)
          
          first_change = json['history'].first['changes'].values.first
          expect(first_change).to have_key('from')
          expect(first_change).to have_key('to')
        end
      end

      context 'with more than 50 history entries' do
        before do
          # Create 60 history entries
          60.times do |i|
            portal_access.update!(email_opt_in: i.even?)
          end
        end

        it 'returns only last 50 entries' do
          get :history
          json = JSON.parse(response.body)
          
          expect(json['history'].length).to eq(50)
        end

        it 'returns most recent entries' do
          get :history
          json = JSON.parse(response.body)
          
          # Timestamps should be in ascending order (oldest first of the last 50)
          timestamps = json['history'].map { |e| e['timestamp'] }
          expect(timestamps).to eq(timestamps.sort)
        end
      end
    end

    context 'without authentication' do
      it 'returns unauthorized status' do
        get :history
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
