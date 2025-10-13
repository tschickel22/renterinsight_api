# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TemplateRenderingService do
  describe '.render' do
    it 'renders simple variable substitution' do
      template = 'Hello {{ name }}'
      result = described_class.render(template, 'name' => 'John')
      
      expect(result).to eq('Hello John')
    end
    
    it 'renders multiple variables' do
      template = 'Hello {{ first_name }} {{ last_name }}'
      result = described_class.render(template, 'first_name' => 'John', 'last_name' => 'Doe')
      
      expect(result).to eq('Hello John Doe')
    end
    
    it 'handles missing variables gracefully' do
      template = 'Hello {{ name }}'
      result = described_class.render(template, {})
      
      expect(result).to include('Hello')
    end
    
    it 'handles nested object attributes' do
      template = 'Total: {{ quote.total }}'
      result = described_class.render(template, 'quote' => { 'total' => '100' })
      
      expect(result).to eq('Total: 100')
    end
    
    it 'returns original template on syntax error' do
      template = 'Hello {{ name'
      result = described_class.render(template, 'name' => 'John')
      
      expect(result).to eq(template)
    end
    
    it 'handles blank templates' do
      expect(described_class.render(nil, {})).to be_nil
      expect(described_class.render('', {})).to eq('')
    end
  end
  
  describe '.build_context_from_record' do
    context 'with Lead' do
      let(:lead) { create(:lead, first_name: 'John', last_name: 'Doe', email: 'john@example.com') }
      
      it 'builds context with lead attributes' do
        context = described_class.build_context_from_record(lead)
        
        expect(context['first_name']).to eq('John')
        expect(context['last_name']).to eq('Doe')
        expect(context['email']).to eq('john@example.com')
        expect(context['full_name']).to eq('John Doe')
      end
      
      it 'includes lead object hash' do
        context = described_class.build_context_from_record(lead)
        
        expect(context['lead']).to be_a(Hash)
        expect(context['lead']['first_name']).to eq('John')
      end
    end
    
    context 'with Account' do
      let(:account) { create(:account, name: 'Acme Corp', email: 'info@acme.com') }
      
      it 'builds context with account attributes' do
        context = described_class.build_context_from_record(account)
        
        expect(context['name']).to eq('Acme Corp')
        expect(context['email']).to eq('info@acme.com')
      end
    end
    
    context 'with Quote' do
      let(:quote) { create(:quote, total: 1500.50) }
      
      it 'builds context with quote attributes' do
        context = described_class.build_context_from_record(quote)
        
        expect(context['quote']).to be_a(Hash)
        expect(context['total']).to eq('$1500.50')
      end
    end
    
    context 'with unsupported record type' do
      it 'returns empty hash' do
        context = described_class.build_context_from_record(Object.new)
        expect(context).to eq({})
      end
    end
  end
  
  describe 'date formatting' do
    it 'formats date values as strings' do
      lead = create(:lead, first_name: 'John')
      context = described_class.build_context_from_record(lead)
      
      # created_at should be formatted as string
      expect(context['lead']['created_at']).to be_a(String)
    end
  end
  
  describe 'ActiveRecord object conversion' do
    let(:lead) { create(:lead, first_name: 'John', last_name: 'Doe') }
    
    it 'converts AR objects to hashes in context' do
      template = 'Hello {{ lead.first_name }}'
      context = { lead: lead }
      
      result = described_class.render(template, context)
      expect(result).to eq('Hello John')
    end
  end
end
