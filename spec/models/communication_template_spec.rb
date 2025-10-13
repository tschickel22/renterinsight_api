# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationTemplate, type: :model do
  describe 'validations' do
    it 'requires a name' do
      template = build(:communication_template, name: nil)
      expect(template).not_to be_valid
      expect(template.errors[:name]).to include("can't be blank")
    end
    
    it 'requires a channel' do
      template = build(:communication_template, channel: nil)
      expect(template).not_to be_valid
      expect(template.errors[:channel]).to include("can't be blank")
    end
    
    it 'validates channel inclusion' do
      template = build(:communication_template, channel: 'invalid')
      expect(template).not_to be_valid
      expect(template.errors[:channel]).to include("is not included in the list")
    end
    
    it 'requires body_template' do
      template = build(:communication_template, body_template: nil)
      expect(template).not_to be_valid
      expect(template.errors[:body_template]).to include("can't be blank")
    end
    
    it 'requires subject_template for email channel' do
      template = build(:communication_template, channel: 'email', subject_template: nil)
      expect(template).not_to be_valid
      expect(template.errors[:subject_template]).to include("can't be blank")
    end
    
    it 'does not require subject_template for SMS channel' do
      template = build(:communication_template, channel: 'sms', subject_template: nil)
      expect(template).to be_valid
    end
  end
  
  describe 'associations' do
    it { should have_many(:communications).with_foreign_key(:template_id).dependent(:nullify) }
  end
  
  describe 'scopes' do
    let!(:active_email) { create(:communication_template, active: true, channel: 'email') }
    let!(:inactive_email) { create(:communication_template, active: false, channel: 'email') }
    let!(:active_sms) { create(:communication_template, active: true, channel: 'sms') }
    
    describe '.active' do
      it 'returns only active templates' do
        expect(described_class.active).to include(active_email, active_sms)
        expect(described_class.active).not_to include(inactive_email)
      end
    end
    
    describe '.for_channel' do
      it 'returns templates for specific channel' do
        expect(described_class.for_channel('email')).to include(active_email, inactive_email)
        expect(described_class.for_channel('email')).not_to include(active_sms)
      end
    end
    
    describe '.by_category' do
      let!(:welcome) { create(:communication_template, category: 'welcome') }
      let!(:quote) { create(:communication_template, category: 'quote') }
      
      it 'returns templates for specific category' do
        expect(described_class.by_category('welcome')).to include(welcome)
        expect(described_class.by_category('welcome')).not_to include(quote)
      end
    end
  end
  
  describe '#extract_variables' do
    it 'extracts variables from body_template' do
      template = create(:communication_template,
        body_template: 'Hello {{ first_name }}, your quote is {{ quote.total }}'
      )
      
      expect(template.available_variables).to include('first_name', 'quote.total')
    end
    
    it 'extracts variables from subject_template for email' do
      template = create(:communication_template,
        channel: 'email',
        subject_template: 'Quote for {{ company_name }}',
        body_template: 'Hello {{ first_name }}'
      )
      
      expect(template.available_variables).to include('company_name', 'first_name')
    end
    
    it 'returns unique variables' do
      template = create(:communication_template,
        body_template: 'Hello {{ first_name }}, {{ first_name }}'
      )
      
      expect(template.available_variables.count('first_name')).to eq(1)
    end
  end
  
  describe '#render' do
    let(:template) do
      create(:communication_template,
        channel: 'email',
        subject_template: 'Hello {{ name }}',
        body_template: 'Your total is {{ total }}'
      )
    end
    
    it 'renders template with context' do
      result = template.render('name' => 'John', 'total' => '100')
      
      expect(result[:subject]).to eq('Hello John')
      expect(result[:body]).to eq('Your total is 100')
    end
    
    it 'handles missing variables gracefully' do
      result = template.render('name' => 'John')
      
      expect(result[:subject]).to eq('Hello John')
      expect(result[:body]).to include('Your total is')
    end
  end
  
  describe '#render_subject' do
    it 'returns nil for SMS templates' do
      template = create(:communication_template, channel: 'sms')
      expect(template.render_subject).to be_nil
    end
    
    it 'renders subject for email templates' do
      template = create(:communication_template,
        channel: 'email',
        subject_template: 'Test {{ variable }}'
      )
      
      expect(template.render_subject('variable' => 'Value')).to eq('Test Value')
    end
  end
  
  describe '#render_body' do
    it 'renders body template' do
      template = create(:communication_template,
        body_template: 'Hello {{ name }}'
      )
      
      expect(template.render_body('name' => 'World')).to eq('Hello World')
    end
  end
end
