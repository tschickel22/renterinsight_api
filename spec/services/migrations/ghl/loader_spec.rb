require 'rails_helper'

RSpec.describe Migrations::Ghl::Loader, type: :service do
  let(:company) { create(:company) }
  let!(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let!(:rep) { company.users.create!(email: 'rep@dealer.example', first_name: 'Rep', last_name: 'One', password: 'secret123', status: 'active', role: 'admin') }
  let(:stop_at) { '2026-10-13T15:00:00Z' }

  let(:data) do
    {
      'reference' => {
        'lead_statuses' => [%w[New new], %w[Contacted contacted]],
        'deal_stages' => [['Deposit Collected', 'deposit_collected', 60, '#000'], ['Closed Won', 'closed_won', 100, '#0f0'],
                          ['Closed Lost', 'closed_lost', 0, '#f00']],
        'project_template' => { 'name' => 'Install', 'template_type' => 'land_home',
                                'phases' => [{ 'name' => 'Permits', 'tasks' => ['Plans Drafted'] }, { 'name' => 'Set', 'tasks' => ['Foundation'] }] },
        'lenders' => ['21st Mortgage'], 'sources' => ['Website'], 'tags' => %w[trove sms_undeliverable],
        'custom_fields' => [{ 'module' => 'lead', 'name' => 'Land Status' }]
      },
      'vendors' => [{ 'ghl_key' => 'vendor:FCA', 'name' => 'FCA', 'vendor_type' => 'contractor', 'source_company_names' => ['FCA'] }],
      'vendor_contacts' => [{ 'ghl_id' => 'v1', 'vendor_key' => 'vendor:FCA', 'first_name' => 'Ann', 'last_name' => 'Lee',
                              'email' => 'ann@fca.example', 'phone' => '+13525550100', 'is_primary' => true, 'extra_emails' => [] }],
      'leads' => [{ 'ghl_id' => 'L1', 'first_name' => 'Joe', 'last_name' => 'Buyer', 'email' => 'joe@example.com', 'phone' => '+13525550111',
                    'status' => 'contacted', 'owner_email' => 'rep@dealer.example', 'source' => 'Website', 'ghl_source' => 'web',
                    'custom' => { 'Land Status' => 'Owned' }, 'site_address' => '1 Main St', 'tags' => ['trove'],
                    'other_opportunities' => [], 'extra_emails' => [], 'created_at' => '2026-06-01T12:00:00Z', 'updated_at' => '2026-06-02T12:00:00Z' }],
      'accounts' => [{ 'ghl_id' => 'account:C1', 'name' => 'Smith Family', 'owner_email' => 'rep@dealer.example', 'billing' => {}, 'tags' => [],
                       'lead_phase_opportunities' => [],
                       'contacts' => [{ 'ghl_id' => 'C1', 'first_name' => 'Pat', 'last_name' => 'Smith', 'phone' => '+13525550122', 'is_primary' => true }] }],
      'deals' => [{ 'ghl_id' => 'D1', 'account_ghl_id' => 'account:C1', 'contact_ghl_id' => 'C1', 'name' => 'Smith home', 'stage' => 'closed_won',
                    'won_at' => '2026-07-01T00:00:00Z', 'owner_email' => 'rep@dealer.example', 'lender' => '21st Mortgage',
                    'ghl_pipeline' => 'Project-Phase', 'ghl_stage' => 'Home Installation', 'ghl_status' => 'open', 'custom' => {} }],
      'projects' => [{ 'ghl_id' => 'project:D1', 'deal_ghl_id' => 'D1', 'name' => 'Smith home', 'status' => 'active',
                       'phases' => [{ 'position' => 0, 'status' => 'completed', 'completed_at' => '2026-07-10', 'tasks' => [{ 'title' => 'Plans Drafted', 'completed' => true }] },
                                    { 'position' => 1, 'status' => 'in_progress', 'tasks' => [{ 'title' => 'Foundation', 'completed' => false }] }] }],
      'notes' => [{ 'ghl_id' => 'note:N1', 'record_type' => 'Lead', 'record_ghl_id' => 'L1', 'content' => 'Wants 3/2', 'created_at' => '2026-06-03T00:00:00Z' }],
      'communications' => [
        { 'ghl_id' => 'M1', 'record_type' => 'Lead', 'record_ghl_id' => 'L1', 'channel' => 'sms', 'direction' => 'inbound', 'body' => 'STOP',
          'at' => stop_at, 'attachments' => [] },
        { 'ghl_id' => 'M2', 'record_type' => 'Contact', 'record_ghl_id' => 'C1', 'channel' => 'call', 'direction' => 'outbound',
          'call_duration' => 125, 'call_status' => 'completed', 'to' => '+13525550122', 'at' => '2026-07-02T15:00:00Z',
          'sent_by_email' => 'rep@dealer.example', 'attachments' => [] }
      ],
      'consent' => [{ 'record_type' => 'Lead', 'record_ghl_id' => 'L1', 'channel' => 'sms', 'scope' => 'all', 'opted_in' => false,
                      'at' => stop_at, 'evidence' => 'texted STOP', 'ghl_message_id' => 'M1' }],
      'rsvps' => [], 'tasks' => [],
      'appointments' => [{ 'ghl_id' => 'E1', 'title' => 'Tour', 'start' => '2026-07-05T14:00:00Z', 'end' => '2026-07-05T15:00:00Z',
                           'record_type' => 'Lead', 'record_ghl_id' => 'L1', 'assigned_email' => 'rep@dealer.example', 'import' => true }],
      'documents' => [], 'media' => []
    }
  end

  def load!(dry_run: false, batch: 'b1')
    described_class.new(company: company, data: data, batch: batch, dry_run: dry_run, log: StringIO.new,
                        steps: described_class::STEPS - %w[documents media]).run
  end

  it 'rolls everything back on a dry run' do
    result = load!(dry_run: true)

    expect(result[:errors]).to be_empty
    expect(result[:report]['lead'][:created]).to eq(1)
    expect(company.leads.count).to eq(0)
    expect(MigrationRecord.where(company_id: company.id).count).to eq(0)
  end

  it 'loads without starting workflows, invites or accounting' do
    expect(AppointmentInviteJob).not_to receive(:perform_later)
    result = load!

    expect(result[:errors]).to be_empty
    expect(WorkflowEvent.where(company_id: company.id).count).to eq(0)
    lead = company.leads.sole
    expect(lead.owner_id).to eq(rep.id)
    expect(lead.custom_field_values).to include('land_status' => 'Owned', 'site_address' => '1 Main St')
    expect(lead.created_at).to eq(Time.zone.parse('2026-06-01T12:00:00Z'))

    deal = company.deals.sole
    expect(deal.stage).to eq('closed_won')
    expect(deal.gl_posted).to be_falsey
    expect(deal.lender&.name).to eq('21st Mortgage')

    meeting = LeadActivity.find_by(lead_id: lead.id, activity_type: 'meeting')
    expect(meeting.remind_customer).to be false
    expect(meeting.send_calendar_invite).to be false
    call = ContactActivity.find_by(activity_type: 'call')
    expect(call.duration_minutes).to eq(3)
    expect(call.account_id).to eq(company.accounts.sole.id)

    project = company.projects.sole
    expect(project.project_phases.order(:position).pluck(:status)).to eq(%w[completed in_progress])
    expect(project.current_phase_id).to eq(project.project_phases.find_by(position: 1).id)

    expect(VendorContact.find_by(company_id: company.id).vendor.name).to eq('FCA')
  end

  it 'keeps the original STOP date and suppresses the number' do
    load!
    lead = company.leads.sole
    pref = CommunicationPreference.find_by(recipient: lead, channel: 'sms', category: nil)

    expect(pref.opted_in).to be false
    expect(pref.opted_out_at).to eq(Time.zone.parse(stop_at))
    expect(pref.compliance_metadata['records'].last).to include('source' => 'gohighlevel_import', 'evidence' => 'texted STOP')
    expect(CampaignSuppression.find_by(company_id: company.id, phone_number: '+13525550111').reason).to eq('sms_stop')
  end

  it 'updates on a second load instead of duplicating' do
    load!
    data['leads'][0]['status'] = 'new'
    result = load!(batch: 'b2')

    expect(result[:errors]).to be_empty
    expect(company.leads.count).to eq(1)
    expect(company.leads.sole.status).to eq('new')
    expect(Communication.where(company_id: company.id).count).to eq(1)
    expect(LeadActivity.where(lead_id: company.leads.sole.id).count).to eq(1)
  end

  it 'takes over statuses and sources the company already has instead of duplicating them' do
    company.lead_statuses.create!(key: 'new', label: 'New')
    company.sources.create!(name: 'website')
    result = load!

    expect(result[:errors]).to be_empty
    expect(company.lead_statuses.where(key: 'new').count).to eq(1)
    expect(company.sources.where('lower(name) = ?', 'website').count).to eq(1)
    expect(result[:report]['lead_status'][:adopted_existing]).to eq(1)
  end

  it 'matches owners to stand-in users when emails are rewritten' do
    standin = company.users.create!(email: 'rep@stage.invalid', first_name: 'S', last_name: 'I', password: 'secret123', status: 'active', role: 'admin')
    described_class.new(company: company, data: data, batch: 'b1', dry_run: false, log: StringIO.new,
                        steps: %w[setup leads], user_email_rewrite: ['@dealer.example', '@stage.invalid']).run

    expect(company.leads.sole.owner_id).to eq(standin.id)
  end

  it 'lists people who were already in the company instead of merging them' do
    company.leads.create!(first_name: 'Joe', email: 'JOE@example.com', status: 'new', skip_workflows: true)
    result = load!

    expect(company.leads.count).to eq(2)
    expect(result[:errors].grep(/possible duplicate: GHL lead L1/).size).to eq(1)
  end

  it 'leaves a record edited in DealerTide alone on a refresh' do
    load!
    lead = company.leads.sole
    lead.update_columns(last_name: 'Changed', updated_at: 1.hour.from_now)
    result = load!(batch: 'b2')

    expect(lead.reload.last_name).to eq('Changed')
    expect(result[:edited].size).to eq(1)
  end
end
