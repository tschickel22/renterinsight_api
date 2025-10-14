# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::Portal::QuotesController, type: :controller do
  let(:company) { Company.first_or_create!(name: 'Test Company') }
  let(:source) { Source.first_or_create!(name: 'Portal') { |s| s.is_active = true } }
  
  describe 'with Lead buyer' do
    let(:lead) { Lead.create!(
      company: company,
      source: source,
      first_name: 'Test',
      last_name: 'Buyer',
      email: 'leadbuyer@example.com',
      phone: '555-1234',
      is_converted: true
    )}
    let(:account) { Account.create!(
      company: company,
      name: 'Lead Buyer Account',
      email: 'leadbuyer@example.com',
      status: 'active'
    )}
    let!(:buyer_access) { BuyerPortalAccess.create!(
      buyer: lead,
      email: 'leadbuyer@example.com',
      password: 'Password123!',
      password_confirmation: 'Password123!'
    )}
    
    before do
      # Link lead to account
      lead.update!(converted_account_id: account.id)
      
      # Authenticate
      token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
      request.headers['Authorization'] = "Bearer #{token}"
    end
    
    describe 'GET #index' do
      let!(:quote1) { Quote.create!(
        account: account,
        quote_number: 'Q-TEST-001',
        status: 'sent',
        subtotal: 100.00,
        tax: 10.00,
        total: 110.00,
        items: [{ description: 'Item 1', quantity: 1, unit_price: '100.00', total: '100.00' }],
        valid_until: 30.days.from_now.to_date,
        sent_at: Time.current
      )}
      
      let!(:quote2) { Quote.create!(
        account: account,
        quote_number: 'Q-TEST-002',
        status: 'viewed',
        subtotal: 200.00,
        tax: 20.00,
        total: 220.00,
        items: [{ description: 'Item 2', quantity: 1, unit_price: '200.00', total: '200.00' }],
        valid_until: 15.days.from_now.to_date,
        sent_at: 2.days.ago,
        viewed_at: 1.day.ago
      )}
      
      let!(:other_account) { Account.create!(company: company, name: 'Other Account', status: 'active') }
      let!(:other_quote) { Quote.create!(
        account: other_account,
        quote_number: 'Q-OTHER-001',
        status: 'sent',
        subtotal: 300.00,
        tax: 30.00,
        total: 330.00,
        valid_until: 30.days.from_now.to_date
      )}
      
      it 'returns only buyer quotes' do
        get :index
        
        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        
        expect(json['ok']).to be true
        expect(json['quotes'].length).to eq(2)
        expect(json['quotes'].map { |q| q['id'] }).to match_array([quote1.id, quote2.id])
      end
      
      it 'filters by status' do
        get :index, params: { status: 'viewed' }
        
        json = JSON.parse(response.body)
        expect(json['quotes'].length).to eq(1)
        expect(json['quotes'][0]['id']).to eq(quote2.id)
      end
      
      it 'includes pagination info' do
        get :index, params: { page: 1, per_page: 1 }
        
        json = JSON.parse(response.body)
        expect(json['pagination']).to include(
          'current_page' => 1,
          'total_pages' => 2,
          'total_count' => 2,
          'per_page' => 1
        )
      end
      
      it 'orders by newest first' do
        get :index
        
        json = JSON.parse(response.body)
        expect(json['quotes'][0]['id']).to eq(quote2.id) # Newer
        expect(json['quotes'][1]['id']).to eq(quote1.id) # Older
      end
      
      it 'does not show deleted quotes' do
        quote1.soft_delete!
        
        get :index
        
        json = JSON.parse(response.body)
        expect(json['quotes'].length).to eq(1)
        expect(json['quotes'][0]['id']).to eq(quote2.id)
      end
      
      it 'requires authentication' do
        request.headers['Authorization'] = nil
        get :index
        
        expect(response).to have_http_status(:unauthorized)
      end
    end
    
    describe 'GET #show' do
      let!(:quote) { Quote.create!(
        account: account,
        quote_number: 'Q-TEST-001',
        status: 'sent',
        subtotal: 100.00,
        tax: 10.00,
        total: 110.00,
        items: [
          { description: 'Oil Change', quantity: 1, unit_price: '45.00', total: '45.00' },
          { description: 'Tire Rotation', quantity: 1, unit_price: '35.00', total: '35.00' }
        ],
        notes: 'Test notes',
        valid_until: 30.days.from_now.to_date,
        sent_at: Time.current
      )}
      
      it 'returns quote details' do
        get :show, params: { id: quote.id }
        
        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        
        expect(json['ok']).to be true
        expect(json['quote']['id']).to eq(quote.id)
        expect(json['quote']['quote_number']).to eq('Q-TEST-001')
        expect(json['quote']['items'].length).to eq(2)
        expect(json['quote']['notes']).to eq('Test notes')
      end
      
      it 'marks quote as viewed on first access' do
        expect(quote.viewed_at).to be_nil
        expect(quote.status).to eq('sent')
        
        get :show, params: { id: quote.id }
        
        quote.reload
        expect(quote.viewed_at).to be_present
        expect(quote.status).to eq('viewed')
      end
      
      it 'does not change viewed_at if already set' do
        quote.update!(status: 'viewed', viewed_at: 1.day.ago)
        original_time = quote.viewed_at
        
        get :show, params: { id: quote.id }
        
        quote.reload
        expect(quote.viewed_at.to_i).to eq(original_time.to_i)
      end
      
      it 'returns 404 for non-existent quote' do
        get :show, params: { id: 99999 }
        
        expect(response).to have_http_status(:not_found)
      end
      
      it 'returns 404 for deleted quote' do
        quote.soft_delete!
        
        get :show, params: { id: quote.id }
        
        expect(response).to have_http_status(:not_found)
      end
      
      it 'returns 403 for other buyer quote' do
        other_account = Account.create!(company: company, name: 'Other Account', status: 'active')
        other_quote = Quote.create!(
          account: other_account,
          quote_number: 'Q-OTHER-001',
          status: 'sent',
          subtotal: 300.00,
          tax: 30.00,
          total: 330.00,
          valid_until: 30.days.from_now.to_date
        )
        
        get :show, params: { id: other_quote.id }
        
        expect(response).to have_http_status(:forbidden)
      end
    end
    
    describe 'POST #accept' do
      let!(:quote) { Quote.create!(
        account: account,
        quote_number: 'Q-TEST-001',
        status: 'sent',
        subtotal: 100.00,
        tax: 10.00,
        total: 110.00,
        items: [{ description: 'Item 1', quantity: 1, unit_price: '100.00', total: '100.00' }],
        valid_until: 30.days.from_now.to_date,
        sent_at: Time.current
      )}
      
      it 'accepts a sent quote' do
        post :accept, params: { id: quote.id }
        
        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        
        expect(json['ok']).to be true
        expect(json['message']).to eq('Quote accepted successfully')
        expect(json['quote']['status']).to eq('accepted')
        
        quote.reload
        expect(quote.status).to eq('accepted')
        expect(quote.accepted_at).to be_present
      end
      
      it 'accepts a viewed quote' do
        quote.update!(status: 'viewed', viewed_at: Time.current)
        
        post :accept, params: { id: quote.id }
        
        expect(response).to have_http_status(:ok)
        quote.reload
        expect(quote.status).to eq('accepted')
      end
      
      it 'creates a note with acceptance' do
        expect {
          post :accept, params: { id: quote.id, notes: 'Please schedule ASAP' }
        }.to change { Note.count }.by(1)
        
        note = Note.last
        expect(note.entity_type).to eq('Quote')
        expect(note.entity_id).to eq(quote.id.to_s)
        expect(note.content).to include('accepted')
        expect(note.content).to include('Please schedule ASAP')
      end
      
      it 'rejects already accepted quote' do
        quote.update!(status: 'accepted', accepted_at: Time.current)
        
        post :accept, params: { id: quote.id }
        
        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json['ok']).to be false
        expect(json['error']).to include('cannot be accepted')
      end
      
      it 'rejects expired quote' do
        quote.update!(valid_until: 1.day.ago.to_date)
        
        post :accept, params: { id: quote.id }
        
        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json['error']).to include('expired')
      end
      
      it 'rejects draft quote' do
        quote.update!(status: 'draft', sent_at: nil)
        
        post :accept, params: { id: quote.id }
        
        expect(response).to have_http_status(:unprocessable_entity)
      end
      
      it 'rejects rejected quote' do
        quote.update!(status: 'rejected', rejected_at: Time.current)
        
        post :accept, params: { id: quote.id }
        
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
    
    describe 'POST #reject' do
      let!(:quote) { Quote.create!(
        account: account,
        quote_number: 'Q-TEST-001',
        status: 'sent',
        subtotal: 100.00,
        tax: 10.00,
        total: 110.00,
        items: [{ description: 'Item 1', quantity: 1, unit_price: '100.00', total: '100.00' }],
        valid_until: 30.days.from_now.to_date,
        sent_at: Time.current
      )}
      
      it 'rejects a sent quote' do
        post :reject, params: { id: quote.id, reason: 'Price too high' }
        
        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        
        expect(json['ok']).to be true
        expect(json['message']).to eq('Quote rejected')
        expect(json['quote']['status']).to eq('rejected')
        
        quote.reload
        expect(quote.status).to eq('rejected')
        expect(quote.rejected_at).to be_present
      end
      
      it 'rejects a viewed quote' do
        quote.update!(status: 'viewed', viewed_at: Time.current)
        
        post :reject, params: { id: quote.id }
        
        expect(response).to have_http_status(:ok)
        quote.reload
        expect(quote.status).to eq('rejected')
      end
      
      it 'creates a note with rejection reason' do
        expect {
          post :reject, params: { id: quote.id, reason: 'Found better price' }
        }.to change { Note.count }.by(1)
        
        note = Note.last
        expect(note.entity_type).to eq('Quote')
        expect(note.entity_id).to eq(quote.id.to_s)
        expect(note.content).to include('rejected')
        expect(note.content).to include('Found better price')
      end
      
      it 'rejects already rejected quote' do
        quote.update!(status: 'rejected', rejected_at: Time.current)
        
        post :reject, params: { id: quote.id }
        
        expect(response).to have_http_status(:unprocessable_entity)
      end
      
      it 'rejects expired quote' do
        quote.update!(valid_until: 1.day.ago.to_date)
        
        post :reject, params: { id: quote.id }
        
        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json['error']).to include('expired')
      end
      
      it 'rejects accepted quote' do
        quote.update!(status: 'accepted', accepted_at: Time.current)
        
        post :reject, params: { id: quote.id }
        
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end
  
  describe 'with Account buyer' do
    let(:account) { Account.create!(
      company: company,
      name: 'Account Buyer',
      email: 'accountbuyer@example.com',
      status: 'active'
    )}
    let!(:buyer_access) { BuyerPortalAccess.create!(
      buyer: account,
      email: 'accountbuyer@example.com',
      password: 'Password123!',
      password_confirmation: 'Password123!'
    )}
    
    before do
      token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
      request.headers['Authorization'] = "Bearer #{token}"
    end
    
    describe 'GET #index' do
      let!(:quote) { Quote.create!(
        account: account,
        quote_number: 'Q-ACCT-001',
        status: 'sent',
        subtotal: 150.00,
        tax: 15.00,
        total: 165.00,
        items: [{ description: 'Service', quantity: 1, unit_price: '150.00', total: '150.00' }],
        valid_until: 30.days.from_now.to_date
      )}
      
      it 'returns account quotes' do
        get :index
        
        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        
        expect(json['ok']).to be true
        expect(json['quotes'].length).to eq(1)
        expect(json['quotes'][0]['id']).to eq(quote.id)
      end
    end
    
    describe 'GET #show' do
      let!(:quote) { Quote.create!(
        account: account,
        quote_number: 'Q-ACCT-001',
        status: 'sent',
        subtotal: 150.00,
        tax: 15.00,
        total: 165.00,
        items: [{ description: 'Service', quantity: 1, unit_price: '150.00', total: '150.00' }],
        valid_until: 30.days.from_now.to_date
      )}
      
      it 'returns account quote details' do
        get :show, params: { id: quote.id }
        
        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['quote']['id']).to eq(quote.id)
      end
    end
  end
end
