# frozen_string_literal: true

require 'rails_helper'

# Direct Meta Lead Ads. Before DealerTide's Meta approval these are the paths
# a test lead from the Lead Ads Testing Tool will take.
RSpec.describe ProcessFacebookLeadJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:owner) do
    User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'Olive', last_name: 'Owner',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let!(:integration) do
    FacebookIntegration.create!(company: company, page_id: 'page-1', page_name: 'Summit Park Homes',
                                page_access_token: 'token', status: 'active', default_owner_id: owner.id)
  end

  let(:graph_lead) do
    {
      'field_data' => [
        { 'name' => 'full_name', 'values' => ['Tia May'] },
        { 'name' => 'email', 'values' => ['tia@example.com'] },
        { 'name' => 'phone_number', 'values' => ['3035551212'] },
        { 'name' => 'what_are_you_looking_for?', 'values' => ['Three bedroom'] }
      ],
      'campaign_name' => 'Spring', 'ad_name' => 'Ad A'
    }
  end

  before do
    allow(MetaGraphApi).to receive(:fetch_lead).and_return(graph_lead)
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
    allow(CommunicationService).to receive(:send_sms).and_return({ success: true })
  end

  def deliver(leadgen_id = 'lg-1')
    described_class.perform_now(page_id: 'page-1', leadgen_id: leadgen_id)
  end

  def company_leads
    Lead.where(company_id: company.id)
  end

  describe 'location' do
    it "lands the lead at the company's default location, not corporate" do
      lead = deliver

      default = company.locations.find_by(is_default: true)
      expect(lead.location_id).to eq(default.id)
      expect(lead.location.is_corporate).to be false
    end

    it 'uses a working location when there is no default, still never corporate' do
      company.locations.find_by(is_default: true).update!(active: false)
      lot = Location.create!(company_id: company.id, name: 'Aurora Lot', code: "AUR-#{SecureRandom.hex(2)}", active: true)

      expect(deliver.location_id).to eq(lot.id)
    end
  end

  it 'records one lead when Meta delivers it twice' do
    deliver('lg-1')

    expect { deliver('lg-1') }.not_to change { company_leads.count }
    expect(MetaGraphApi).to have_received(:fetch_lead).once
  end

  it 'folds a returning person into their record and tells their owner' do
    existing = Lead.create!(company_id: company.id, first_name: 'Tia', last_name: 'May',
                            email: 'tia@example.com', owner_id: owner.id)

    expect { deliver('lg-2') }.not_to change { company_leads.count }

    note = Note.where(entity_type: 'lead', entity_id: existing.id.to_s).order(:id).last
    expect(note.content).to include('REPEAT INQUIRY via Facebook Lead Ads: Summit Park Homes')
    expect(note.content).to include('Three bedroom')
    reminder = LeadActivity.where(lead_id: existing.id, activity_type: 'reminder').order(:id).last
    expect(reminder.assigned_to_id).to eq(owner.id)
  end

  it "does not start a new-lead workflow directly, since the lead's own event starts it" do
    rule = WorkflowRule.create!(
      company_id: company.id, name: 'Welcome', entity_type: 'Lead', status: 'active',
      trigger: { 'event_type' => 'lead.created' }, conditions: [],
      steps: { 'nodes' => [{ 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 1 } }] }
    )
    integration.update!(default_workflow_id: rule.id)

    deliver
    expect(WorkflowRun.where(workflow_rule_id: rule.id).count).to eq(0)

    DispatchWorkflowEventsJob.new.perform
    expect(WorkflowRun.where(workflow_rule_id: rule.id).count).to eq(1)
  end
  describe 'form answers' do
    it 'writes every custom question to the notes column and the Notes tab' do
      lead = deliver

      expect(lead.notes).to include('Form answers:')
      expect(lead.notes).to include('What are you looking for?: Three bedroom')
      tab = Note.where(entity_type: 'lead', entity_id: lead.id.to_s).last
      expect(tab.content).to include('What are you looking for?: Three bedroom')
      expect(lead.survey_answers).to eq('what_are_you_looking_for?' => 'Three bedroom')
    end

    it 'keeps an answer the dealer mapped to Notes instead of dropping it' do
      integration.update!(field_mapping: { 'what_are_you_looking_for?' => 'notes' })

      expect(deliver.notes).to include('Three bedroom')
    end

    it 'drops an answer the dealer chose to ignore' do
      integration.update!(field_mapping: { 'what_are_you_looking_for?' => 'ignore' })

      lead = deliver
      expect(lead.notes).not_to include('Three bedroom')
      expect(lead.survey_answers).to be_blank
    end

    it 'fills a lead column the dealer mapped a question to' do
      integration.update!(field_mapping: { 'what_are_you_looking_for?' => 'preferred_home_type' })

      expect(deliver.preferred_home_type).to eq('Three bedroom')
    end
  end

  describe 'custom fields' do
    let!(:custom_field) do
      CustomField.create!(company_id: company.id, module: 'leads', field_key: 'home_wanted',
                          name: 'home_wanted', label: 'What are you looking for',
                          field_type: 'text', is_active: true, display_order: 0)
    end

    it 'fills a custom field the dealer mapped a question to' do
      integration.update!(field_mapping: { 'what_are_you_looking_for?' => 'custom:home_wanted' })

      expect(deliver.custom_field_values).to eq('home_wanted' => 'Three bedroom')
    end

    it 'matches an unmapped question to a custom field by its label' do
      expect(deliver.custom_field_values).to eq('home_wanted' => 'Three bedroom')
    end
  end

  it 'marks the lead as arriving through Facebook Lead Ads' do
    expect(deliver.origin).to eq(Lead::ORIGIN_FACEBOOK)
  end
end
