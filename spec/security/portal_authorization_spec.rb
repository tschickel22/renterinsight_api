# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Portal Security & Authorization', type: :request do
  let(:company) { Company.create!(name: 'Test Company') }
  let(:source) { Source.create!(name: 'Test Source', source_type: 'website', is_active: true) }
  
  let(:buyer1_lead) do
    Lead.create!(
      first_name: 'Alice',
      last_name: 'Smith',
      email: 'alice@example.com',
      phone: '555-1111',
      source: source,
      company: company,
      is_converted: true
    )
  end
  
  let(:account1) do
    Account.create!(
      company: company,
      name: 'Alice Account',
      email: 'alice@example.com',
      status: 'active'
    )
  end
  
  let(:buyer1_access) do
    BuyerPortalAccess.create!(
      buyer: buyer1_lead,
      email: 'alice@example.com',
      password: 'Password123!',
      password_confirmation: 'Password123!',
      portal_enabled: true
    )
  end
  
  let(:buyer1_token) do
    JWT.encode(
      { buyer_id: buyer1_lead.id, buyer_type: 'Lead', exp: 24.hours.from_now.to_i },
      Rails.application.secret_key_base,
      'HS256'
    )
  end
  
  let(:buyer2_lead) do
    Lead.create!(
      first_name: 'Bob',
      last_name: 'Jones',
      email: 'bob@example.com',
      phone: '555-2222',
      source: source,
      company: company,
      is_converted: true
    )
  end
  
  let(:account2) do
    Account.create!(
      company: company,
      name: 'Bob Account',
      email: 'bob@example.com',
      status: 'active'
    )
  end
  
  let(:buyer2_access) do
    BuyerPortalAccess.create!(
      buyer: buyer2_lead,
      email: 'bob@example.com',
      password: 'Password456!',
      password_confirmation: 'Password456!',
      portal_enabled: true
    )
  end
  
  let(:buyer2_token) do
    JWT.encode(
      { buyer_id: buyer2_lead.id, buyer_type: 'Lead', exp: 24.hours.from_now.to_i },
      Rails.application.secret_key_base,
      'HS256'
    )
  end
  
  before do
    buyer1_lead.update!(converted_account_id: account1.id)
    buyer2_lead.update!(converted_account_id: account2.id)
  end
  
  describe 'Communications Isolation' do
    before do
      @buyer1_thread = CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: buyer1_lead.id,
        channel: 'portal_message',
        subject: 'Alice Private',
        status: 'active',
        last_message_at: Time.current
      )
      
      @buyer1_comm = Communication.create!(
        communicable: buyer1_lead,
        communication_thread: @buyer1_thread,
        direction: 'outbound',
        channel: 'email',
        provider: 'smtp',
        status: 'sent',
        subject: 'Alice Private Message',
        body: 'Alice private data',
        from_address: 'support@example.com',
        to_address: 'alice@example.com',
        portal_visible: true,
        sent_at: Time.current
      )
      
      @buyer2_thread = CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: buyer2_lead.id,
        channel: 'portal_message',
        subject: 'Bob Private',
        status: 'active',
        last_message_at: Time.current
      )
      
      @buyer2_comm = Communication.create!(
        communicable: buyer2_lead,
        communication_thread: @buyer2_thread,
        direction: 'outbound',
        channel: 'email',
        provider: 'smtp',
        status: 'sent',
        subject: 'Bob Private Message',
        body: 'Bob private data',
        from_address: 'support@example.com',
        to_address: 'bob@example.com',
        portal_visible: true,
        sent_at: Time.current
      )
    end
    
    it 'buyer 1 sees only own communications' do
      get '/api/portal/communications', headers: { 'Authorization' => "Bearer #{buyer1_token}" }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['communications'].length).to eq(1)
      expect(data['communications'].first['body']).to eq('Alice private data')
    end
    
    it 'buyer 2 sees only own communications' do
      get '/api/portal/communications', headers: { 'Authorization' => "Bearer #{buyer2_token}" }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['communications'].length).to eq(1)
      expect(data['communications'].first['body']).to eq('Bob private data')
    end
    
    it 'buyer 1 cannot reply to buyer 2 thread' do
      post "/api/portal/communications/#{@buyer2_thread.id}/reply",
           params: { body: 'Attack' }.to_json,
           headers: { 'Authorization' => "Bearer #{buyer1_token}", 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
    end
  end
  
  describe 'Quotes Isolation' do
    before do
      @buyer1_quote = Quote.create!(
        account: account1,
        quote_number: 'Q-ALICE-001',
        status: 'sent',
        subtotal: 1000.00,
        tax: 100.00,
        total: 1100.00,
        items: [{ description: 'Service', quantity: 1, unit_price: '1000.00', total: '1000.00' }],
        valid_until: 30.days.from_now.to_date,
        sent_at: Time.current
      )
      
      @buyer2_quote = Quote.create!(
        account: account2,
        quote_number: 'Q-BOB-001',
        status: 'sent',
        subtotal: 2000.00,
        tax: 200.00,
        total: 2200.00,
        items: [{ description: 'Service', quantity: 1, unit_price: '2000.00', total: '2000.00' }],
        valid_until: 30.days.from_now.to_date,
        sent_at: Time.current
      )
    end
    
    it 'buyer 1 sees only own quotes' do
      get '/api/portal/quotes', headers: { 'Authorization' => "Bearer #{buyer1_token}" }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['quotes'].length).to eq(1)
      expect(data['quotes'].first['quote_number']).to eq('Q-ALICE-001')
    end
    
    it 'buyer 2 sees only own quotes' do
      get '/api/portal/quotes', headers: { 'Authorization' => "Bearer #{buyer2_token}" }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['quotes'].length).to eq(1)
      expect(data['quotes'].first['quote_number']).to eq('Q-BOB-001')
    end
    
    it 'buyer 1 cannot view buyer 2 quote' do
      get "/api/portal/quotes/#{@buyer2_quote.id}",
          headers: { 'Authorization' => "Bearer #{buyer1_token}" }
      expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
    end
    
    it 'buyer 1 cannot accept buyer 2 quote' do
      patch "/api/portal/quotes/#{@buyer2_quote.id}/accept",
            headers: { 'Authorization' => "Bearer #{buyer1_token}", 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
    end
  end
  
  describe 'Token Security' do
    it 'rejects expired token' do
      expired = JWT.encode(
        { buyer_id: buyer1_lead.id, buyer_type: 'Lead', exp: 1.hour.ago.to_i },
        Rails.application.secret_key_base,
        'HS256'
      )
      get '/api/portal/communications', headers: { 'Authorization' => "Bearer #{expired}" }
      expect(response).to have_http_status(:unauthorized)
    end
    
    it 'rejects invalid token' do
      get '/api/portal/communications', headers: { 'Authorization' => 'Bearer invalid' }
      expect(response).to have_http_status(:unauthorized)
    end
    
    it 'rejects missing auth header' do
      get '/api/portal/communications'
      expect(response).to have_http_status(:unauthorized)
    end
    
    it 'rejects wrong buyer_id in token' do
      wrong_token = JWT.encode(
        { buyer_id: 99999, buyer_type: 'Lead', exp: 24.hours.from_now.to_i },
        Rails.application.secret_key_base,
        'HS256'
      )
      get '/api/portal/communications', headers: { 'Authorization' => "Bearer #{wrong_token}" }
      expect(response).to have_http_status(:unauthorized).or have_http_status(:not_found)
    end
  end
  
  describe 'Disabled Portal Access' do
    it 'prevents login when portal is disabled' do
      buyer1_access.update!(portal_enabled: false)
      
      post '/api/portal/auth/login',
           params: { email: 'alice@example.com', password: 'Password123!' }.to_json,
           headers: { 'Content-Type' => 'application/json' }
      
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
