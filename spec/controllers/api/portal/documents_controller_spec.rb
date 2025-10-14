# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::Portal::DocumentsController, type: :controller do
  let(:company) { Company.first_or_create!(name: 'Test Company') }
  let(:source) { Source.first_or_create!(name: 'Portal') { |s| s.is_active = true } }
  
  let(:lead) { Lead.create!(
    company: company,
    source: source,
    first_name: 'Test',
    last_name: 'Buyer',
    email: 'buyer@example.com',
    is_converted: true
  )}
  
  let(:account) { Account.create!(
    company: company,
    name: 'Test Account',
    email: 'buyer@example.com',
    status: 'active'
  )}
  
  let!(:buyer_access) { BuyerPortalAccess.create!(
    buyer: lead,
    email: 'buyer@example.com',
    password: 'Password123!',
    password_confirmation: 'Password123!'
  )}
  
  let(:other_lead) { Lead.create!(
    company: company,
    source: source,
    first_name: 'Other',
    last_name: 'Buyer',
    email: 'other@example.com'
  )}
  
  before do
    lead.update!(converted_account_id: account.id)
    token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
    request.headers['Authorization'] = "Bearer #{token}"
  end
  
  describe 'GET #index' do
    let!(:document1) { create_document(lead, 'doc1.pdf', 'insurance') }
    let!(:document2) { create_document(lead, 'doc2.pdf', 'registration') }
    let!(:document3) { create_document(lead, 'doc3.pdf', 'insurance') }
    let!(:other_doc) { create_document(other_lead, 'other.pdf', 'insurance') }
    
    it 'returns buyer documents' do
      get :index
      
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be true
      expect(json['documents'].length).to eq(3)
      
      # Should not include other buyer's documents
      filenames = json['documents'].map { |d| d['filename'] }
      expect(filenames).to include('doc1.pdf', 'doc2.pdf', 'doc3.pdf')
      expect(filenames).not_to include('other.pdf')
    end
    
    it 'includes expected document fields' do
      get :index
      
      json = JSON.parse(response.body)
      doc = json['documents'].first
      
      expect(doc.keys).to include(
        'id', 'filename', 'content_type', 'size', 
        'category', 'uploaded_at', 'uploaded_by', 'url'
      )
    end
    
    it 'filters by category' do
      get :index, params: { category: 'insurance' }
      
      json = JSON.parse(response.body)
      expect(json['documents'].length).to eq(2)
      
      json['documents'].each do |doc|
        expect(doc['category']).to eq('insurance')
      end
    end
    
    it 'paginates results' do
      get :index, params: { per_page: 2 }
      
      json = JSON.parse(response.body)
      expect(json['documents'].length).to eq(2)
      expect(json['pagination']['per_page']).to eq(2)
      expect(json['pagination']['total_count']).to eq(3)
      expect(json['pagination']['total_pages']).to eq(2)
    end
    
    it 'supports page parameter' do
      get :index, params: { per_page: 2, page: 2 }
      
      json = JSON.parse(response.body)
      expect(json['documents'].length).to eq(1)
      expect(json['pagination']['current_page']).to eq(2)
    end
    
    it 'limits per_page to max of 100' do
      get :index, params: { per_page: 200 }
      
      json = JSON.parse(response.body)
      expect(json['pagination']['per_page']).to eq(100)
    end
    
    it 'sorts by uploaded_at descending (newest first)' do
      # Update timestamps to test sorting
      document1.update_column(:uploaded_at, 3.days.ago)
      document2.update_column(:uploaded_at, 1.day.ago)
      document3.update_column(:uploaded_at, 2.days.ago)
      
      get :index
      
      json = JSON.parse(response.body)
      filenames = json['documents'].map { |d| d['filename'] }
      expect(filenames).to eq(['doc2.pdf', 'doc3.pdf', 'doc1.pdf'])
    end
    
    it 'requires authentication' do
      request.headers['Authorization'] = nil
      get :index
      
      expect(response).to have_http_status(:unauthorized)
    end
    
    it 'rejects invalid token' do
      request.headers['Authorization'] = 'Bearer invalid_token'
      get :index
      
      expect(response).to have_http_status(:unauthorized)
    end
    
    it 'returns empty array when no documents' do
      PortalDocument.destroy_all
      
      get :index
      
      json = JSON.parse(response.body)
      expect(json['ok']).to be true
      expect(json['documents']).to eq([])
      expect(json['pagination']['total_count']).to eq(0)
    end
  end
  
  describe 'GET #show' do
    let!(:document) { create_document(lead, 'test.pdf', 'insurance', 'Test insurance document') }
    
    it 'returns document details' do
      get :show, params: { id: document.id }
      
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be true
      expect(json['document']['id']).to eq(document.id)
      expect(json['document']['filename']).to eq('test.pdf')
      expect(json['document']['category']).to eq('insurance')
      expect(json['document']['description']).to eq('Test insurance document')
    end
    
    it 'includes all detail fields' do
      get :show, params: { id: document.id }
      
      json = JSON.parse(response.body)
      doc = json['document']
      
      expect(doc.keys).to include(
        'id', 'filename', 'content_type', 'size', 
        'category', 'uploaded_at', 'uploaded_by', 'url',
        'description', 'related_to'
      )
    end
    
    it 'includes related_to info when document has relationship' do
      quote = Quote.create!(
        account: account,
        quote_number: 'Q-2025-001',
        status: 'sent',
        subtotal: 1000,
        tax: 100,
        total: 1100
      )
      
      document.update!(related_to: quote)
      
      get :show, params: { id: document.id }
      
      json = JSON.parse(response.body)
      related = json['document']['related_to']
      
      expect(related).to be_present
      expect(related['type']).to eq('Quote')
      expect(related['id']).to eq(quote.id)
      expect(related['reference']).to eq('Q-2025-001')
    end
    
    it 'returns 404 for non-existent document' do
      get :show, params: { id: 99999 }
      
      expect(response).to have_http_status(:not_found)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be false
      expect(json['error']).to eq('Document not found')
    end
    
    it 'returns 403 for unauthorized document' do
      other_doc = create_document(other_lead, 'other.pdf', 'insurance')
      
      get :show, params: { id: other_doc.id }
      
      expect(response).to have_http_status(:forbidden)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be false
      expect(json['error']).to eq('Unauthorized')
    end
    
    it 'requires authentication' do
      request.headers['Authorization'] = nil
      get :show, params: { id: document.id }
      
      expect(response).to have_http_status(:unauthorized)
    end
  end
  
  describe 'POST #create' do
    let(:file) { 
      fixture_file_upload(
        Rails.root.join('spec/fixtures/files/test.pdf'), 
        'application/pdf'
      ) 
    }
    
    it 'uploads a document' do
      expect {
        post :create, params: {
          file: file,
          category: 'insurance',
          description: 'Test document'
        }
      }.to change { PortalDocument.count }.by(1)
      
      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be true
      expect(json['message']).to eq('Document uploaded successfully')
      expect(json['document']['filename']).to eq('test.pdf')
      expect(json['document']['category']).to eq('insurance')
    end
    
    it 'sets owner to current buyer' do
      post :create, params: {
        file: file,
        category: 'insurance'
      }
      
      document = PortalDocument.last
      expect(document.owner).to eq(lead)
    end
    
    it 'sets uploaded_by to buyer' do
      post :create, params: {
        file: file,
        category: 'insurance'
      }
      
      document = PortalDocument.last
      expect(document.uploaded_by).to eq('buyer')
    end
    
    it 'sets uploaded_at timestamp' do
      post :create, params: {
        file: file,
        category: 'insurance'
      }
      
      document = PortalDocument.last
      expect(document.uploaded_at).to be_within(5.seconds).of(Time.current)
    end
    
    it 'allows optional description' do
      post :create, params: {
        file: file,
        description: 'My insurance card'
      }
      
      document = PortalDocument.last
      expect(document.description).to eq('My insurance card')
    end
    
    it 'allows optional related_to fields' do
      quote = Quote.create!(
        account: account,
        quote_number: 'Q-2025-001',
        status: 'draft',
        subtotal: 1000,
        tax: 100,
        total: 1100
      )
      
      post :create, params: {
        file: file,
        related_to_type: 'Quote',
        related_to_id: quote.id
      }
      
      document = PortalDocument.last
      expect(document.related_to).to eq(quote)
    end
    
    it 'validates file presence' do
      post :create, params: {
        category: 'insurance'
      }
      
      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be false
      expect(json['error']).to eq('Document upload failed')
      expect(json['errors']).to include("File can't be blank")
    end
    
    it 'validates category values' do
      post :create, params: {
        file: file,
        category: 'invalid_category'
      }
      
      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      
      expect(json['errors']).to include(
        match(/Category is not included in the list/)
      )
    end
    
    it 'allows nil category' do
      post :create, params: {
        file: file
      }
      
      expect(response).to have_http_status(:created)
      document = PortalDocument.last
      expect(document.category).to be_nil
    end
    
    it 'allows valid categories' do
      %w[insurance registration invoice receipt other].each do |category|
        post :create, params: {
          file: file,
          category: category
        }
        
        expect(response).to have_http_status(:created)
      end
    end
    
    it 'requires authentication' do
      request.headers['Authorization'] = nil
      
      post :create, params: {
        file: file,
        category: 'insurance'
      }
      
      expect(response).to have_http_status(:unauthorized)
    end
  end
  
  describe 'GET #download' do
    let!(:document) { create_document(lead, 'test.pdf', 'insurance') }
    
    it 'downloads the file' do
      get :download, params: { id: document.id }
      
      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to eq('application/pdf')
      expect(response.headers['Content-Disposition']).to include('attachment')
      expect(response.headers['Content-Disposition']).to include('test.pdf')
    end
    
    it 'returns file content' do
      get :download, params: { id: document.id }
      
      expect(response.body).not_to be_empty
      expect(response.body).to include('%PDF')
    end
    
    it 'returns 404 for document without file' do
      document.file.purge
      
      get :download, params: { id: document.id }
      
      expect(response).to have_http_status(:not_found)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be false
      expect(json['error']).to eq('File not found')
    end
    
    it 'returns 404 for non-existent document' do
      get :download, params: { id: 99999 }
      
      expect(response).to have_http_status(:not_found)
    end
    
    it 'returns 403 for unauthorized document' do
      other_doc = create_document(other_lead, 'other.pdf', 'insurance')
      
      get :download, params: { id: other_doc.id }
      
      expect(response).to have_http_status(:forbidden)
    end
    
    it 'requires authentication' do
      request.headers['Authorization'] = nil
      get :download, params: { id: document.id }
      
      expect(response).to have_http_status(:unauthorized)
    end
  end
  
  describe 'DELETE #destroy' do
    let!(:document) { create_document(lead, 'test.pdf', 'insurance') }
    
    it 'deletes the document' do
      expect {
        delete :destroy, params: { id: document.id }
      }.to change { PortalDocument.count }.by(-1)
      
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      
      expect(json['ok']).to be true
      expect(json['message']).to eq('Document deleted successfully')
    end
    
    it 'purges the attached file' do
      blob_id = document.file.blob.id
      
      delete :destroy, params: { id: document.id }
      
      expect(ActiveStorage::Blob.exists?(blob_id)).to be false
    end
    
    it 'returns 404 for non-existent document' do
      delete :destroy, params: { id: 99999 }
      
      expect(response).to have_http_status(:not_found)
    end
    
    it 'returns 403 for unauthorized document' do
      other_doc = create_document(other_lead, 'other.pdf', 'insurance')
      
      delete :destroy, params: { id: other_doc.id }
      
      expect(response).to have_http_status(:forbidden)
    end
    
    it 'requires authentication' do
      request.headers['Authorization'] = nil
      delete :destroy, params: { id: document.id }
      
      expect(response).to have_http_status(:unauthorized)
    end
  end
  
  private
  
  def create_document(owner, filename, category, description = nil)
    doc = PortalDocument.new(
      owner: owner,
      category: category,
      description: description,
      uploaded_by: 'buyer'
    )
    
    # Attach a test file
    file_path = Rails.root.join('spec/fixtures/files/test.pdf')
    doc.file.attach(
      io: File.open(file_path),
      filename: filename,
      content_type: 'application/pdf'
    )
    
    doc.save!
    doc
  end
end
