# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AttachmentService do
  let(:lead) { create(:lead) }
  let(:communication) { create(:communication, communicable: lead) }
  
  describe '.validate_attachment' do
    context 'with valid file' do
      let(:file) do
        double('file',
          size: 1.megabyte,
          content_type: 'application/pdf',
          original_filename: 'document.pdf'
        )
      end
      
      it 'returns valid result' do
        result = described_class.validate_attachment(file)
        
        expect(result[:valid]).to be true
        expect(result[:errors]).to be_empty
      end
    end
    
    context 'with nil file' do
      it 'returns invalid with error' do
        result = described_class.validate_attachment(nil)
        
        expect(result[:valid]).to be false
        expect(result[:errors]).to include('File is required')
      end
    end
    
    context 'with oversized file' do
      let(:file) do
        double('file',
          size: 26.megabytes,
          content_type: 'application/pdf',
          original_filename: 'large.pdf'
        )
      end
      
      it 'returns invalid with size error' do
        result = described_class.validate_attachment(file)
        
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(match(/exceeds maximum/))
      end
    end
    
    context 'with invalid content type' do
      let(:file) do
        double('file',
          size: 1.megabyte,
          content_type: 'application/x-executable',
          original_filename: 'virus.exe'
        )
      end
      
      it 'returns invalid with type error' do
        result = described_class.validate_attachment(file)
        
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(match(/not allowed/))
      end
    end
    
    context 'with missing filename' do
      let(:file) do
        double('file',
          size: 1.megabyte,
          content_type: 'application/pdf',
          original_filename: ''
        )
      end
      
      it 'returns invalid with filename error' do
        result = described_class.validate_attachment(file)
        
        expect(result[:valid]).to be false
        expect(result[:errors]).to include('Filename is required')
      end
    end
  end
  
  describe '.attach_to_communication' do
    let(:valid_file) do
      double('file',
        size: 1.megabyte,
        content_type: 'application/pdf',
        original_filename: 'document.pdf'
      )
    end
    
    it 'attaches valid file to communication' do
      allow(communication.attachments).to receive(:attach).with(valid_file)
      allow(communication.attachments).to receive(:last).and_return(
        double('attachment', id: 1, filename: 'document.pdf', byte_size: 1.megabyte, content_type: 'application/pdf')
      )
      
      result = described_class.attach_to_communication(communication, valid_file)
      
      expect(result[:success]).to be true
      expect(result[:filename]).to eq('document.pdf')
    end
    
    it 'rejects invalid file' do
      invalid_file = double('file', size: 26.megabytes, content_type: 'application/pdf', original_filename: 'large.pdf')
      
      result = described_class.attach_to_communication(communication, invalid_file)
      
      expect(result[:success]).to be false
      expect(result[:errors]).not_to be_empty
    end
  end
  
  describe '.attach_multiple_to_communication' do
    let(:file1) do
      double('file',
        size: 1.megabyte,
        content_type: 'application/pdf',
        original_filename: 'doc1.pdf'
      )
    end
    
    let(:file2) do
      double('file',
        size: 2.megabytes,
        content_type: 'image/png',
        original_filename: 'image.png'
      )
    end
    
    let(:invalid_file) do
      double('file',
        size: 30.megabytes,
        content_type: 'application/pdf',
        original_filename: 'huge.pdf'
      )
    end
    
    it 'attaches multiple valid files' do
      allow(communication.attachments).to receive(:attach)
      allow(communication.attachments).to receive(:last).and_return(
        double('attachment', id: 1, filename: 'doc.pdf', byte_size: 1.megabyte, content_type: 'application/pdf')
      )
      
      result = described_class.attach_multiple_to_communication(communication, [file1, file2])
      
      expect(result[:success]).to be true
      expect(result[:attached].count).to eq(2)
      expect(result[:failed]).to be_empty
    end
    
    it 'reports failures for invalid files' do
      allow(communication.attachments).to receive(:attach)
      allow(communication.attachments).to receive(:last).and_return(
        double('attachment', id: 1, filename: 'doc.pdf', byte_size: 1.megabyte, content_type: 'application/pdf')
      )
      
      result = described_class.attach_multiple_to_communication(communication, [file1, invalid_file])
      
      expect(result[:success]).to be false
      expect(result[:attached].count).to eq(1)
      expect(result[:failed].count).to eq(1)
    end
  end
  
  describe '.allowed_content_type?' do
    it 'returns true for allowed types' do
      expect(described_class.allowed_content_type?('application/pdf')).to be true
      expect(described_class.allowed_content_type?('image/png')).to be true
      expect(described_class.allowed_content_type?('application/vnd.openxmlformats-officedocument.wordprocessingml.document')).to be true
    end
    
    it 'returns false for disallowed types' do
      expect(described_class.allowed_content_type?('application/x-executable')).to be false
      expect(described_class.allowed_content_type?('video/mp4')).to be false
    end
  end
  
  describe '.format_size' do
    it 'formats bytes correctly' do
      expect(described_class.format_size(500)).to eq('500 B')
      expect(described_class.format_size(1.kilobyte)).to eq('1.0 KB')
      expect(described_class.format_size(1.5.megabytes)).to eq('1.5 MB')
    end
  end
  
  describe '.allowed_extensions' do
    it 'returns list of allowed extensions' do
      extensions = described_class.allowed_extensions
      
      expect(extensions).to include('.pdf', '.docx', '.png', '.jpg')
    end
  end
end
