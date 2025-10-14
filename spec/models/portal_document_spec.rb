# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PortalDocument, type: :model do
  let(:company) { Company.first_or_create!(name: 'Test Company') }
  let(:source) { Source.first_or_create!(name: 'Portal') { |s| s.is_active = true } }
  
  let(:lead) { Lead.create!(
    company: company,
    source: source,
    first_name: 'Test',
    last_name: 'Buyer',
    email: 'test@example.com'
  )}
  
  describe 'associations' do
    it { should belong_to(:owner) }
    it { should belong_to(:related_to).optional }
    
    it 'accepts Lead as owner' do
      doc = PortalDocument.new(owner: lead, uploaded_by: 'buyer')
      expect(doc.owner).to eq(lead)
    end
    
    it 'accepts Account as owner' do
      account = Account.create!(
        company: company,
        name: 'Test Account',
        email: 'test@example.com'
      )
      
      doc = PortalDocument.new(owner: account, uploaded_by: 'buyer')
      expect(doc.owner).to eq(account)
    end
  end
  
  describe 'validations' do
    it { should validate_presence_of(:owner_type) }
    it { should validate_presence_of(:owner_id) }
    
    it 'validates owner_type is Lead or Account' do
      doc = PortalDocument.new(
        owner_type: 'Contact',  # Invalid type (not Lead or Account)
        owner_id: 1,
        uploaded_by: 'buyer'
      )
      
      expect(doc).not_to be_valid
      expect(doc.errors[:owner_type]).to include(
        'is not included in the list'
      )
    end
    
    it 'validates category values' do
      doc = PortalDocument.new(
        owner: lead,
        category: 'invalid_category',
        uploaded_by: 'buyer'
      )
      
      expect(doc).not_to be_valid
      expect(doc.errors[:category]).to include(
        'is not included in the list'
      )
    end
    
    it 'allows valid categories' do
      %w[insurance registration invoice receipt other].each do |category|
        doc = PortalDocument.new(
          owner: lead,
          category: category,
          uploaded_by: 'buyer'
        )
        
        expect(doc.category).to eq(category)
      end
    end
    
    it 'allows nil category' do
      doc = PortalDocument.new(
        owner: lead,
        category: nil,
        uploaded_by: 'buyer'
      )
      
      # Attach a file to pass validation
      file_path = Rails.root.join('spec/fixtures/files/test.pdf')
      doc.file.attach(
        io: File.open(file_path),
        filename: 'test.pdf',
        content_type: 'application/pdf'
      )
      
      expect(doc).to be_valid
    end
  end
  
  describe 'scopes' do
    let!(:doc1) { create_document(lead, 'doc1.pdf', 'insurance') }
    let!(:doc2) { create_document(lead, 'doc2.pdf', 'registration') }
    
    let(:other_lead) { Lead.create!(
      company: company,
      source: source,
      first_name: 'Other',
      last_name: 'Buyer',
      email: 'other@example.com'
    )}
    
    let!(:doc3) { create_document(other_lead, 'doc3.pdf', 'insurance') }
    
    describe '.by_owner' do
      it 'returns documents for specific owner' do
        docs = PortalDocument.by_owner(lead)
        expect(docs).to include(doc1, doc2)
        expect(docs).not_to include(doc3)
      end
    end
    
    describe '.by_category' do
      it 'returns documents for specific category' do
        docs = PortalDocument.by_category('insurance')
        expect(docs).to include(doc1, doc3)
        expect(docs).not_to include(doc2)
      end
    end
    
    describe '.recent' do
      it 'orders by uploaded_at descending' do
        doc1.update_column(:uploaded_at, 3.days.ago)
        doc2.update_column(:uploaded_at, 1.day.ago)
        doc3.update_column(:uploaded_at, 2.days.ago)
        
        docs = PortalDocument.recent.to_a
        expect(docs.first).to eq(doc2)
        expect(docs.last).to eq(doc1)
      end
    end
  end
  
  describe 'callbacks' do
    describe 'before_create :set_uploaded_at' do
      it 'sets uploaded_at on create' do
        doc = create_document(lead, 'test.pdf', 'insurance')
        expect(doc.uploaded_at).to be_within(5.seconds).of(Time.current)
      end
      
      it 'does not override manually set uploaded_at' do
        custom_time = 2.days.ago
        doc = PortalDocument.new(
          owner: lead,
          uploaded_by: 'buyer',
          uploaded_at: custom_time
        )
        
        file_path = Rails.root.join('spec/fixtures/files/test.pdf')
        doc.file.attach(
          io: File.open(file_path),
          filename: 'test.pdf',
          content_type: 'application/pdf'
        )
        
        doc.save!
        expect(doc.uploaded_at).to be_within(1.second).of(custom_time)
      end
    end
  end
  
  describe 'instance methods' do
    let(:document) { create_document(lead, 'test.pdf', 'insurance') }
    
    describe '#filename' do
      it 'returns attached file filename' do
        expect(document.filename).to eq('test.pdf')
      end
      
      it 'returns empty string when no file attached' do
        document.file.purge
        expect(document.filename).to eq('')
      end
    end
    
    describe '#content_type' do
      it 'returns attached file content type' do
        expect(document.content_type).to eq('application/pdf')
      end
      
      it 'returns nil when no file attached' do
        document.file.purge
        expect(document.content_type).to be_nil
      end
    end
    
    describe '#size' do
      it 'returns attached file size' do
        expect(document.size).to be > 0
      end
      
      it 'returns nil when no file attached' do
        document.file.purge
        expect(document.size).to be_nil
      end
    end
    
    describe '#download_url' do
      it 'returns correct URL path' do
        expect(document.download_url).to eq("/api/portal/documents/#{document.id}/download")
      end
    end
  end
  
  describe 'Active Storage attachment' do
    it 'has one attached file' do
      doc = PortalDocument.new(owner: lead, uploaded_by: 'buyer')
      expect(doc).to respond_to(:file)
    end
    
    it 'can attach a file' do
      doc = create_document(lead, 'test.pdf', 'insurance')
      expect(doc.file).to be_attached
    end
    
    it 'can purge attached file' do
      doc = create_document(lead, 'test.pdf', 'insurance')
      blob_id = doc.file.blob.id
      
      doc.file.purge
      
      expect(doc.file).not_to be_attached
      expect(ActiveStorage::Blob.exists?(blob_id)).to be false
    end
  end
  
  private
  
  def create_document(owner, filename, category)
    doc = PortalDocument.new(
      owner: owner,
      category: category,
      uploaded_by: 'buyer'
    )
    
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
