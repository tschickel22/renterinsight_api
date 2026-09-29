# frozen_string_literal: true

require 'rails_helper'

RSpec::Matchers.define_negated_matcher :not_change, :change unless RSpec::Matchers.method_defined?(:not_change)

# Pulling a Page's recent Lead Ads history. The live webhook treats a lead as
# a fresh inquiry; an import must not, or a lead play texts people who asked
# weeks ago and every rep gets an alert per existing customer.
RSpec.describe FacebookLeads::Import do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:owner) do
    User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'Olive', last_name: 'Owner',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let!(:integration) do
    FacebookIntegration.create!(company: company, page_id: 'page-1', page_name: 'Summit Park Homes',
                                page_access_token: 'token', status: 'active', default_owner_id: owner.id)
  end

  def fb_lead(id, name:, email:, phone: nil, created: 10.days.ago)
    fields = [{ 'name' => 'full_name', 'values' => [name] }, { 'name' => 'email', 'values' => [email] },
              { 'name' => 'what_are_you_looking_for?', 'values' => ['Three bedroom'] }]
    fields << { 'name' => 'phone_number', 'values' => [phone] } if phone
    { 'id' => id, 'created_time' => created.iso8601, 'field_data' => fields, 'campaign_name' => 'Spring' }
  end

  let(:forms) { [{ 'id' => 'form-a', 'name' => 'Spring Homes' }, { 'id' => 'form-b', 'name' => 'Financing' }] }
  let(:leads_by_form) do
    {
      'form-a' => [fb_lead('lg-new', name: 'Tia May', email: 'tia@example.com', created: 20.days.ago),
                   fb_lead('lg-known', name: 'Ray Known', email: 'ray@example.com'),
                   fb_lead('lg-done', name: 'Dee Done', email: 'dee@example.com')],
      # Same person on a second form: one lead, not two.
      'form-b' => [fb_lead('lg-again', name: 'Tia May', email: 'TIA@example.com')]
    }
  end

  before do
    allow(MetaGraphApi).to receive(:each_lead_form) { |*_args, &block| forms.each(&block) }
    allow(MetaGraphApi).to receive(:each_form_lead) { |form_id, *_args, **_opts, &block| leads_by_form[form_id].each(&block) }

    Lead.create!(company_id: company.id, first_name: 'Ray', last_name: 'Known', email: 'ray@example.com')
    Lead.create!(company_id: company.id, first_name: 'Dee', last_name: 'Done', email: 'other@example.com',
                 facebook_leadgen_id: 'lg-done')
  end

  def run(dry_run:)
    described_class.new(integration, dry_run: dry_run).call
  end

  it 'counts what it would bring in and writes nothing on a dry run' do
    result = nil
    expect { result = run(dry_run: true) }.not_to change { Lead.count }

    expect(result.to_h.slice(:forms, :found, :already_imported, :already_in_crm, :imported, :failed))
      .to eq(forms: 2, found: 4, already_imported: 1, already_in_crm: 2, imported: 1, failed: 0)
  end

  it 'adds only the missing lead, quietly, with its real submission date' do
    new_lead_rule = WorkflowRule.create!(
      company_id: company.id, name: 'Welcome', entity_type: 'Lead', status: 'active',
      trigger: { 'event_type' => 'lead.created' }, conditions: [],
      steps: { 'nodes' => [{ 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 1 } }] }
    )

    expect { run(dry_run: false) }.to change { Lead.count }.by(1)
                                  .and(not_change { WorkflowEvent.where(event_type: 'lead.created').count })
                                  .and(not_change { Notification.count })

    lead = Lead.find_by!(company_id: company.id, facebook_leadgen_id: 'lg-new')
    expect(lead).to have_attributes(first_name: 'Tia', email: 'tia@example.com', origin: Lead::ORIGIN_FACEBOOK,
                                    owner_id: owner.id)
    expect(lead.source_created_at).to be_within(1.minute).of(20.days.ago)
    expect(lead.notes).to include('Imported from Facebook', 'on the form "Spring Homes"', 'What are you looking for?: Three bedroom')
    expect(Note.where(entity_type: 'lead', entity_id: lead.id.to_s).last.content).to include('Three bedroom')

    DispatchWorkflowEventsJob.new.perform
    expect(WorkflowRun.where(workflow_rule_id: new_lead_rule.id, entity_type: 'Lead', entity_id: lead.id)).to be_empty

    # The existing record got nothing written to it.
    known = Lead.find_by!(company_id: company.id, email: 'ray@example.com')
    expect(Note.where(entity_type: 'lead', entity_id: known.id.to_s)).to be_empty
  end

  it 'is safe to run twice' do
    run(dry_run: false)

    expect { run(dry_run: false) }.not_to change { Lead.count }
  end
end

RSpec.describe MetaGraphApi do
  it 'follows the paging cursor to the last page' do
    pages = [
      { 'data' => [{ 'id' => '1' }], 'paging' => { 'cursors' => { 'after' => 'c1' }, 'next' => 'https://next' } },
      { 'data' => [{ 'id' => '2' }], 'paging' => { 'cursors' => { 'after' => 'c2' } } }
    ]
    allow(described_class).to receive(:get).and_return(*pages)

    ids = []
    described_class.each_form_lead('form-a', 'token', since: 90.days.ago) { |lead| ids << lead['id'] }

    expect(ids).to eq(%w[1 2])
    expect(described_class).to have_received(:get).with('/form-a/leads', 'token', hash_including(after: 'c1'))
  end
end
