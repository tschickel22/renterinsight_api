# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::Portal::CommunicationsController, type: :controller do
  let(:company) { Company.create!(name: 'Test Company') }
  let(:source) { Source.create!(name: 'Test Source', source_type: 'website', is_active: true) }
  
  let(:lead) do
    Lead.create!(
      first_name: 'Jane',
      last_name: 'Smith',
      email: 'jane@example.com',
      phone: '555-0100',
      source: source,
      company: company
    )
  end
  
  let(:portal_access) do
    BuyerPortalAccess.create!(
      buyer: lead,
      email: 'jane@example.com',
      password: 'Password123!',
      password_confirmation: 'Password123!',
      portal_enabled: true
    )
  end
  
  let(:valid_token) do
    JWT.encode(
      { buyer_id: lead.id, buyer_type: 'Lead', exp: 24.hours.from_now.to_i },
      Rails.application.secret_key_base,
      'HS256'
    )
  end
  
before do
    @token = JsonWebToken.encode(buyer_portal_access_id: portal_access.id)
    @request.headers['Authorization'] = "Bearer #{@token}"
  end
  
  describe 'GET #index' do
    let!(:thread1) do
      CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: lead.id,
        channel: 'portal_message',
        subject: 'Thread 1',
        status: 'active',
        last_message_at: 2.days.ago
      )
    end
    
    let!(:thread2) do
      CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: lead.id,
        channel: 'email',
        subject: 'Thread 2',
        status: 'active',
        last_message_at: 1.day.ago
      )
    end
    
    let!(:comm1) do
      Communication.create!(
        communicable: lead,
        communication_thread: thread1,
        direction: 'outbound',
        channel: 'email',
        provider: 'smtp',
        status: 'sent',
        subject: 'Welcome',
        body: 'Welcome to our service',
        from_address: 'support@example.com',
        to_address: 'jane@example.com',
        portal_visible: true,
        sent_at: 2.days.ago
      )
    end
    
    let!(:comm2) do
      Communication.create!(
        communicable: lead,
        communication_thread: thread2,
        direction: 'outbound',
        channel: 'email',
        provider: 'smtp',
        status: 'sent',
        subject: 'Update',
        body: 'Here is an update',
        from_address: 'support@example.com',
        to_address: 'jane@example.com',
        portal_visible: true,
        sent_at: 1.day.ago
      )
    end
    
    let!(:hidden_comm) do
      Communication.create!(
        communicable: lead,
        communication_thread: thread1,
        direction: 'outbound',
        channel: 'email',
        provider: 'smtp',
        status: 'sent',
        subject: 'Internal',
        body: 'Internal only',
        from_address: 'support@example.com',
        to_address: 'jane@example.com',
        portal_visible: false,
        sent_at: 3.days.ago
      )
    end
    
    it 'returns only portal-visible communications' do
      get :index
      
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['communications'].length).to eq(2)
      expect(data['communications'].map { |c| c['id'] }).to match_array([comm1.id, comm2.id])
    end
    
    it 'orders by most recent first' do
      get :index
      
      data = JSON.parse(response.body)
      expect(data['communications'].first['id']).to eq(comm2.id)
      expect(data['communications'].last['id']).to eq(comm1.id)
    end
    
    it 'supports pagination' do
      get :index, params: { page: 1, per_page: 1 }
      
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['communications'].length).to eq(1)
      expect(data['pagination']).to be_present
      expect(data['pagination']['total']).to eq(2)
    end
    
    it 'filters by read status' do
      comm1.update!(read_at: Time.current)
      
      get :index, params: { read: 'false' }
      
      data = JSON.parse(response.body)
      expect(data['communications'].length).to eq(1)
      expect(data['communications'].first['id']).to eq(comm2.id)
    end
    
    it 'requires authentication' do
      request.headers['Authorization'] = nil
      get :index
      
      expect(response).to have_http_status(:unauthorized)
    end
  end
  
  describe 'GET #show' do
    let(:thread) do
      CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: lead.id,
        channel: 'portal_message',
        subject: 'Test Thread'
      )
    end
    
    let(:communication) do
      Communication.create!(
        communicable: lead,
        communication_thread: thread,
        direction: 'outbound',
        channel: 'email',
        provider: 'smtp',
        status: 'sent',
        subject: 'Test',
        body: 'Test message',
        from_address: 'support@example.com',
        to_address: 'jane@example.com',
        portal_visible: true,
        sent_at: Time.current
      )
    end
    
    it 'returns communication details' do
      get :show, params: { id: communication.id }
      
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['communication']['id']).to eq(communication.id)
      expect(data['communication']['body']).to eq('Test message')
    end
    
    it 'marks as read on first view' do
      expect(communication.read_at).to be_nil
      
      get :show, params: { id: communication.id }
      
      communication.reload
      expect(communication.read_at).to be_present
    end
    
    it 'does not change read_at if already read' do
      original_read_at = 1.hour.ago
      communication.update!(read_at: original_read_at)
      
      get :show, params: { id: communication.id }
      
      communication.reload
      expect(communication.read_at.to_i).to eq(original_read_at.to_i)
    end
    
    it 'returns 404 for non-existent communication' do
      get :show, params: { id: 99999 }
      
      expect(response).to have_http_status(:not_found)
    end
    
    it 'returns 404 for hidden communication' do
      communication.update!(portal_visible: false)
      
      get :show, params: { id: communication.id }
      
      expect(response).to have_http_status(:not_found)
    end
  end
  
  describe 'POST #create (reply)' do
    let(:thread) do
      CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: lead.id,
        channel: 'portal_message',
        subject: 'Inquiry'
      )
    end
    
    it 'creates a reply in the thread' do
      expect {
        post :create, params: {
          thread_id: thread.id,
          body: 'This is my reply'
        }
      }.to change(Communication, :count).by(2) # Reply + internal notification
      
      expect(response).to have_http_status(:created)
      data = JSON.parse(response.body)
      expect(data['communication']['body']).to eq('This is my reply')
      expect(data['communication']['direction']).to eq('inbound')
    end
    
    it 'sends notification to internal team' do
      expect(BuyerPortalService).to receive(:notify_internal_of_reply)
      
      post :create, params: {
        thread_id: thread.id,
        body: 'This is my reply'
      }
      
      expect(response).to have_http_status(:created)
    end
    
    it 'requires body parameter' do
      post :create, params: { thread_id: thread.id }
      
      expect(response).to have_http_status(:unprocessable_entity)
    end
    
    it 'requires valid thread_id' do
      post :create, params: {
        thread_id: 99999,
        body: 'Test'
      }
      
      expect(response).to have_http_status(:not_found)
    end
    
    it 'prevents reply to another buyer\'s thread' do
      other_lead = Lead.create!(
        first_name: 'Bob',
        last_name: 'Jones',
        email: 'bob@example.com',
        source: source,
        company: company
      )
      
      other_thread = CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: other_lead.id,
        channel: 'portal_message',
        subject: 'Other Thread'
      )
      
      post :create, params: {
        thread_id: other_thread.id,
        body: 'Unauthorized reply'
      }
      
      expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
    end
  end
  
  describe 'PATCH #mark_as_read' do
    let(:thread) do
      CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: lead.id,
        channel: 'portal_message',
        subject: 'Test'
      )
    end
    
    let(:communication) do
      Communication.create!(
        communicable: lead,
        communication_thread: thread,
        direction: 'outbound',
        channel: 'email',
        provider: 'smtp',
        status: 'sent',
        subject: 'Test',
        body: 'Test message',
        from_address: 'support@example.com',
        to_address: 'jane@example.com',
        portal_visible: true,
        sent_at: Time.current
      )
    end

before do
  @token = JsonWebToken.encode(buyer_portal_access_id: portal_access.id)
  @request.headers['Authorization'] = "Bearer #{@token}"
end
    
    it 'marks communication as read' do
      expect(communication.read_at).to be_nil
      
      patch :mark_as_read, params: { id: communication.id }
      
      expect(response).to have_http_status(:ok)
      communication.reload
      expect(communication.read_at).to be_present
    end
  end
  
  describe 'GET #threads' do
    let!(:thread1) do
      CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: lead.id,
        channel: 'portal_message',
        subject: 'Thread 1',
        status: 'active',
        last_message_at: 2.days.ago
      )
    end
    
    let!(:thread2) do
      CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: lead.id,
        channel: 'email',
        subject: 'Thread 2',
        status: 'active',
        last_message_at: 1.day.ago
      )
    end
    
    before do
      Communication.create!(
        communicable: lead,
        communication_thread: thread1,
        direction: 'outbound',
        channel: 'email',
        status: 'sent',
        subject: 'Thread 1',
        body: 'Message 1',
        from_address: 'support@example.com',
        to_address: 'jane@example.com',
        portal_visible: true,
        sent_at: 2.days.ago
      )
      
      Communication.create!(
        communicable: lead,
        communication_thread: thread2,
        direction: 'outbound',
        channel: 'email',
        status: 'sent',
        subject: 'Thread 2',
        body: 'Message 2',
        from_address: 'support@example.com',
        to_address: 'jane@example.com',
        portal_visible: true,
        sent_at: 1.day.ago
      )
    end
    
    it 'returns list of threads' do
      get :threads
      
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['threads'].length).to eq(2)
    end
    
    it 'orders threads by most recent message' do
      get :threads
      
      data = JSON.parse(response.body)
      expect(data['threads'].first['id']).to eq(thread2.id)
      expect(data['threads'].last['id']).to eq(thread1.id)
    end
  end
end
