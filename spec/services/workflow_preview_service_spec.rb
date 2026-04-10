# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkflowPreviewService, type: :service do
  let(:company)   { create(:company) }
  let(:company_b) { create(:company) }
  let(:source)    { create(:source, company: company, name: 'Website') }

  before do
    # Create leads for company A
    create(:lead, company: company, source: source, status: 'new', first_name: 'Alice')
    create(:lead, company: company, source: source, status: 'new', first_name: 'Bob')
    create(:lead, company: company, source: source, status: 'contacted', first_name: 'Carol')
    # Create lead for company B (should never appear)
    create(:lead, company: company_b, status: 'new', first_name: 'Eve')
  end

  describe '.preview' do
    context 'lead created trigger with source condition' do
      let(:rule) do
        create(:workflow_rule,
          company: company,
          entity_type: 'lead',
          trigger: { 'event_type' => 'lead.created' },
          conditions: {
            'type' => 'and',
            'children' => [
              { 'field' => 'status', 'operator' => 'equals', 'value' => 'new' }
            ]
          },
          steps: { 'nodes' => [], 'edges' => [] }
        )
      end

      it 'returns matched leads scoped to company' do
        result = described_class.preview(rule, company: company)

        expect(result[:matched_count]).to eq(2)
        expect(result[:total_count]).to eq(3) # all company A leads
        expect(result[:sample_entities].length).to eq(2)
        expect(result[:sample_entities].map { |e| e[:label] }).not_to include('Eve')
      end
    end

    context 'empty conditions' do
      let(:rule) do
        create(:workflow_rule,
          company: company,
          entity_type: 'lead',
          trigger: { 'event_type' => 'lead.created' },
          conditions: {},
          steps: { 'nodes' => [], 'edges' => [] }
        )
      end

      it 'returns warning about no conditions' do
        result = described_class.preview(rule, company: company)

        expect(result[:warnings]).to include("Rule has no conditions — will fire on every lead")
        expect(result[:matched_count]).to eq(3) # all company A leads match
      end
    end

    context 'invalid nurture_sequence_id in actions' do
      let(:rule) do
        create(:workflow_rule,
          company: company,
          entity_type: 'lead',
          trigger: { 'event_type' => 'lead.created' },
          conditions: {},
          steps: {
            'nodes' => [
              { 'id' => 'step1', 'type' => 'enroll_in_nurture', 'config' => { 'nurture_sequence_id' => 99999 } }
            ],
            'edges' => []
          }
        )
      end

      it 'returns warning about missing nurture sequence' do
        result = described_class.preview(rule, company: company)

        expect(result[:warnings]).to include("Action references nurture_sequence_id 99999 which does not exist")
        expect(result[:action_simulations].first[:warnings]).to include(
          "Action references nurture_sequence_id 99999 which does not exist"
        )
      end
    end

    context 'valid nurture_sequence_id in actions' do
      let(:nurture_seq) { create(:nurture_sequence, company: company, name: 'Website Leads') }
      let(:rule) do
        create(:workflow_rule,
          company: company,
          entity_type: 'lead',
          trigger: { 'event_type' => 'lead.created' },
          conditions: {},
          steps: {
            'nodes' => [
              { 'id' => 'step1', 'type' => 'enroll_in_nurture', 'config' => { 'nurture_sequence_id' => nurture_seq.id } }
            ],
            'edges' => []
          }
        )
      end

      it 'returns simulation with sequence name' do
        result = described_class.preview(rule, company: company)

        sim = result[:action_simulations].first
        expect(sim[:type]).to eq('enroll_in_nurture')
        expect(sim[:summary]).to include('Website Leads')
      end
    end

    context 'tenant isolation' do
      let(:rule_b) do
        create(:workflow_rule,
          company: company_b,
          entity_type: 'lead',
          trigger: { 'event_type' => 'lead.created' },
          conditions: {},
          steps: { 'nodes' => [], 'edges' => [] }
        )
      end

      it 'only previews entities from the rule company' do
        result = described_class.preview(rule_b, company: company_b)

        expect(result[:total_count]).to eq(1) # only Eve
        expect(result[:matched_count]).to eq(1)
        expect(result[:sample_entities].first[:label]).to include('Eve')
      end
    end

    context 'inactivity trigger' do
      let(:rule) do
        create(:workflow_rule,
          company: company,
          entity_type: 'lead',
          trigger: { 'event_type' => 'inactivity_14d' },
          conditions: {},
          steps: { 'nodes' => [], 'edges' => [] }
        )
      end

      it 'filters by updated_at older than N days' do
        # Make one lead stale
        stale_lead = company.leads.first
        stale_lead.update_columns(updated_at: 20.days.ago)

        result = described_class.preview(rule, company: company)

        expect(result[:matched_count]).to eq(1)
        expect(result[:sample_entities].first[:id]).to eq(stale_lead.id)
      end
    end

    context 'executes zero side effects' do
      let(:nurture_seq) { create(:nurture_sequence, company: company, name: 'Test') }
      let(:rule) do
        create(:workflow_rule,
          company: company,
          entity_type: 'lead',
          trigger: { 'event_type' => 'lead.created' },
          conditions: {},
          steps: {
            'nodes' => [
              { 'id' => 'step1', 'type' => 'enroll_in_nurture', 'config' => { 'nurture_sequence_id' => nurture_seq.id } },
              { 'id' => 'step2', 'type' => 'update_field', 'config' => { 'field' => 'status', 'value' => 'contacted' } },
              { 'id' => 'step3', 'type' => 'add_tag', 'config' => { 'tag_name' => 'hot' } }
            ],
            'edges' => []
          }
        )
      end

      it 'does not create any records or modify entities' do
        # Force lazy lets to resolve before the change check
        rule
        expect {
          described_class.preview(rule, company: company)
        }.not_to change { [Lead.count, NurtureSequence.count] }

        # Verify leads were not updated
        company.leads.reload.each do |lead|
          expect(lead.status).not_to eq('contacted') if lead.first_name != 'Carol'
        end
      end
    end
  end
end
