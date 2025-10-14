# frozen_string_literal: true

require 'rails_helper'

RSpec.describe QuotePresenter do
  let(:company) { Company.first_or_create!(name: 'Test Company') }
  let(:account) { Account.create!(
    company: company,
    name: 'Test Account',
    email: 'test@example.com',
    phone: '555-1234',
    status: 'active'
  )}
  
  let(:quote) { 
    # Create account first, then build quote with proper items that calculate to our expected totals
    q = Quote.new(
      account: account,
      quote_number: 'Q-TEST-001',
      status: 'sent',
      items: [
        { description: 'Oil Change', quantity: 1, unit_price: '45.00', total: '45.00' },
        { description: 'Tire Rotation', quantity: 2, unit_price: '35.50', total: '71.00' }
      ],
      notes: 'Test notes',
      custom_fields: { warranty: '1 year' },
      valid_until: 30.days.from_now.to_date,
      sent_at: Time.current,
      vehicle_id: 'VIN123'
    )
    # Subtotal will be calculated: 45 + 71 = 116
    q.tax = 11.60  # 10% tax
    q.save!
    q
  }
  
  describe '.basic_json' do
    let(:result) { QuotePresenter.basic_json(quote) }
    
    it 'includes basic quote fields' do
      expect(result[:id]).to eq(quote.id)
      expect(result[:quote_number]).to eq('Q-TEST-001')
      expect(result[:status]).to eq('sent')
    end
    
    it 'formats money as strings' do
      expect(result[:subtotal]).to eq('116.0')  # 45 + 71
      expect(result[:tax]).to eq('11.6')
      expect(result[:total]).to eq('127.6')  # 116 + 11.6
    end
    
    it 'includes timestamps' do
      expect(result[:sent_at]).to be_present
      expect(result[:created_at]).to be_present
      expect(result[:updated_at]).to be_present
    end
    
    it 'includes null timestamps when not set' do
      expect(result[:viewed_at]).to be_nil
      expect(result[:accepted_at]).to be_nil
      expect(result[:rejected_at]).to be_nil
    end
  end
  
  describe '.detailed_json' do
    let(:result) { QuotePresenter.detailed_json(quote) }
    
    it 'includes all basic fields' do
      expect(result[:id]).to eq(quote.id)
      expect(result[:quote_number]).to eq('Q-TEST-001')
    end
    
    it 'includes items array' do
      expect(result[:items]).to be_an(Array)
      expect(result[:items].length).to eq(2)
    end
    
    it 'formats items correctly' do
      first_item = result[:items][0]
      expect(first_item[:description]).to eq('Oil Change')
      expect(first_item[:quantity]).to eq(1)
      expect(first_item[:unit_price]).to eq('45.0')
      expect(first_item[:total]).to eq('45.0')
    end
    
    it 'includes notes' do
      expect(result[:notes]).to eq('Test notes')
    end
    
    it 'includes custom_fields' do
      expect(result[:custom_fields]).to eq({ 'warranty' => '1 year' })
    end
    
    it 'includes vehicle_info when vehicle_id present' do
      expect(result[:vehicle_info]).to be_present
      expect(result[:vehicle_info][:vehicle_id]).to eq('VIN123')
    end
    
    it 'includes account_info' do
      expect(result[:account_info]).to be_present
      expect(result[:account_info][:id]).to eq(account.id)
      expect(result[:account_info][:name]).to eq('Test Account')
      expect(result[:account_info][:email]).to eq('test@example.com')
      expect(result[:account_info][:phone]).to eq(account.phone)  # Use actual saved value
    end
  end
  
  describe 'with nil values' do
    let(:minimal_quote) { Quote.create!(
      account: account,
      quote_number: 'Q-MIN-001',
      status: 'draft',
      subtotal: 0,
      tax: 0,
      total: 0
    )}
    
    it 'handles nil items' do
      result = QuotePresenter.detailed_json(minimal_quote)
      expect(result[:items]).to eq([])
    end
    
    it 'handles nil custom_fields' do
      result = QuotePresenter.detailed_json(minimal_quote)
      expect(result[:custom_fields]).to eq({})
    end
    
    it 'handles nil vehicle_id' do
      result = QuotePresenter.detailed_json(minimal_quote)
      expect(result[:vehicle_info]).to be_nil
    end
  end
  
  describe 'item formatting edge cases' do
    it 'handles various item key formats' do
      quote_with_keys = Quote.create!(
        account: account,
        quote_number: 'Q-KEYS-001',
        status: 'draft',
        subtotal: 100,
        tax: 10,
        total: 110,
        items: [
          { 'description' => 'Item 1', 'quantity' => 1, 'unit_price' => '50.00', 'total' => '50.00' },
          { description: 'Item 2', quantity: 2, unitPrice: '25.00', total: '50.00' }
        ]
      )
      
      result = QuotePresenter.detailed_json(quote_with_keys)
      expect(result[:items].length).to eq(2)
      expect(result[:items][0][:description]).to eq('Item 1')
      expect(result[:items][1][:description]).to eq('Item 2')
    end
    
    it 'filters out invalid items' do
      quote_with_invalid = Quote.create!(
        account: account,
        quote_number: 'Q-INV-001',
        status: 'draft',
        subtotal: 100,
        tax: 10,
        total: 110,
        items: [
          { description: 'Valid Item', quantity: 1, unit_price: '100.00', total: '100.00' },
          'invalid item string',
          nil
        ]
      )
      
      result = QuotePresenter.detailed_json(quote_with_invalid)
      expect(result[:items].length).to eq(1)
      expect(result[:items][0][:description]).to eq('Valid Item')
    end
  end
end
