require 'rails_helper'

RSpec.describe Migrations::Zoho::Loader, type: :service do
  let(:company) { create(:company) }
  let!(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let!(:rep) { company.users.create!(email: 'rep@renterinsight.com', first_name: 'Rep', last_name: 'One', password: 'secret123', status: 'active', role: 'admin') }

  let(:data) do
    {
      'company_id' => company.id,
      'mapped_at' => '2026-11-19T12:00:00Z',
      'reference' => {
        'lead_statuses' => [['Dormant', 'dormant', true]],
        'deal_stage_keys' => %w[prospecting closed_won closed_lost],
        'sources' => ['Google Ads', 'Trade Show'],
        'custom_fields' => [{ 'module' => 'accounts', 'name' => 'Number of Units', 'field_type' => 'number' },
                            { 'module' => 'leads', 'name' => 'Property Type', 'field_type' => 'select',
                              'options' => ['Apartment', 'Condo', 'House'] },
                            { 'module' => 'deals', 'name' => 'Competition', 'field_type' => 'select' }]
      },
      'accounts' => [
        { 'zoho_id' => 'A1', 'name' => 'Parkview Management', 'status' => 'active', 'account_type' => 'customer',
          'email' => 'info@parkview.example', 'phone' => '+13035550100', 'website' => 'parkview.example',
          'annual_revenue' => '1,250,000', 'employee_count' => '40', 'owner_email' => 'rep@renterinsight.com',
          'source' => 'Trade Show', 'billing' => { 'street' => '1 Main St', 'city' => 'Denver', 'state' => 'CO', 'zip' => '80202' },
          'custom' => { 'Number of Units' => '430', 'Company Type' => 'Fee Manager' },
          'created_at' => '2026-02-01T12:00:00Z' },
        { 'zoho_id' => 'A2', 'name' => 'Parkview East', 'parent_zoho_id' => 'A1', 'owner_email' => 'rep@renterinsight.com',
          'custom' => { 'Company Type' => 'Reseller / Partner' }, 'created_at' => '2026-03-01T12:00:00Z' }
      ],
      'contacts' => [
        { 'zoho_id' => 'C1', 'account_zoho_id' => 'A1', 'first_name' => 'Pat', 'last_name' => 'Smith',
          'email' => 'pat@parkview.example', 'phone' => '+13035550122', 'title' => 'Owner', 'is_primary' => true,
          'owner_email' => 'rep@renterinsight.com', 'custom' => {}, 'created_at' => '2026-02-02T12:00:00Z' },
        # Zoho requires Last_Name and lets First_Name be blank; contacts.first_name is NOT NULL.
        { 'zoho_id' => 'C2', 'account_zoho_id' => 'A1', 'first_name' => nil, 'last_name' => 'Nofirst',
          'email' => 'nofirst@parkview.example', 'custom' => {}, 'created_at' => '2026-02-03T12:00:00Z' }
      ],
      'leads' => [
        { 'zoho_id' => 'L1', 'first_name' => 'Joe', 'last_name' => 'Buyer', 'email' => 'joe@example.com',
          'phone' => '+13035550111', 'status' => 'dormant', 'company_name' => 'Buyer Realty', 'title' => 'Principal',
          'owner_email' => 'rep@renterinsight.com', 'source' => 'Google Ads', 'budget_range' => '$500/mo',
          'purchase_timeframe' => '6 months', 'interests_requirements' => 'Wants online applications',
          'custom' => { 'Property Type' => 'Apartment' }, 'created_at' => '2026-06-01T12:00:00Z',
          'updated_at' => '2026-06-02T12:00:00Z', 'last_activity_at' => '2026-06-02T12:00:00Z' }
      ],
      'deals' => [
        { 'zoho_id' => 'D1', 'account_zoho_id' => 'A1', 'contact_zoho_id' => 'C1', 'name' => 'Parkview rollout',
          'stage' => 'closed_won', 'value' => '24,000', 'probability' => '100',
          'actual_close_date' => '2026-07-01', 'owner_email' => 'rep@renterinsight.com',
          'zoho_pipeline' => 'Standard', 'zoho_stage' => 'Closed Won', 'custom' => {},
          'created_at' => '2026-04-01T12:00:00Z' },
        { 'zoho_id' => 'D2', 'account_zoho_id' => 'A1', 'name' => 'Parkview east pilot',
          'stage' => 'closed_lost', 'value' => '9,000', 'actual_close_date' => '2026-08-01',
          'loss_reason' => 'Lost to Competition', 'competitor' => 'Appfolio',
          'zoho_pipeline' => 'Standard', 'zoho_stage' => 'Closed-Lost to Competition', 'custom' => {},
          'created_at' => '2026-05-01T12:00:00Z' }
      ],
      'notes' => [
        { 'zoho_id' => 'N1', 'parent_module' => 'Leads', 'parent_zoho_id' => 'L1', 'title' => 'Discovery',
          'content' => 'Wants rent payments first', 'author_email' => 'rep@renterinsight.com',
          'created_at' => '2026-06-03T00:00:00Z' },
        { 'zoho_id' => 'N2', 'parent_module' => 'Accounts', 'parent_zoho_id' => 'A1',
          'content' => 'Renewal in March', 'created_at' => '2026-06-04T00:00:00Z' },
        { 'zoho_id' => 'N3', 'parent_module' => 'Campaigns', 'parent_zoho_id' => 'X1', 'content' => 'ignored' }
      ]
    }
  end

  def load!(dry_run: false, batch: 'b1', **kwargs)
    described_class.new(company: company, data: data, batch: batch, dry_run: dry_run,
                        log: StringIO.new, **kwargs).run
  end

  it 'rolls everything back on a dry run' do
    result = load!(dry_run: true)

    expect(result[:report]['account'][:created]).to eq(2)
    expect(company.accounts.count).to eq(0)
    expect(MigrationRecord.where(company_id: company.id).count).to eq(0)
  end

  it 'loads accounts, contacts, leads, deals and notes' do
    result = load!

    expect(company.accounts.count).to eq(2)
    account = company.accounts.find_by(name: 'Parkview Management')
    expect(account.account_type).to eq('customer')
    expect(account.custom_field_values).to include('company_type' => 'Fee Manager')
    expect(account.annual_revenue).to eq(1_250_000)
    expect(account.employee_count).to eq(40)
    expect(account.owner_id).to eq(rep.id)
    expect(account.location_id).to eq(location.id)
    expect(account.billing_postal_code).to eq('80202')
    expect(account.custom_field_values).to include('number_of_units' => '430')
    expect(account.created_at).to eq(Time.zone.parse('2026-02-01T12:00:00Z'))

    lead = company.leads.sole
    expect(lead.company_name).to eq('Buyer Realty')
    expect(lead.budget_range).to eq('$500/mo')
    expect(lead.purchase_timeframe).to eq('6 months')
    expect(lead.interests_requirements).to eq('Wants online applications')
    expect(lead.custom_field_values).to include('property_type' => 'Apartment')
    expect(result[:errors]).to be_empty
  end

  it 'derives partner from the Zoho company type when no account_type is given' do
    load!

    expect(company.accounts.find_by(name: 'Parkview East').account_type).to eq('partner')
  end

  it 'replaces an account_type outside the enum rather than failing the account' do
    data['accounts'][0]['account_type'] = 'Fee Manager'
    result = load!

    account = company.accounts.find_by(name: 'Parkview Management')
    expect(account).to be_present
    expect(account.account_type).to eq('customer')
    expect(result[:report]['account_type'][:replaced]).to eq(1)
    expect(result[:errors].join).to include('not one of Account::ACCOUNT_TYPES')
  end

  it 'creates a select custom field with its options and downgrades one without' do
    result = load!

    prop = CustomField.find_by(company_id: company.id, module: 'leads', field_key: 'property_type')
    expect(prop.field_type).to eq('select')
    expect(prop.options).to eq(['Apartment', 'Condo', 'House'])

    # No options came through for this one, so free text beats failing the field.
    comp = CustomField.find_by(company_id: company.id, module: 'deals', field_key: 'competition')
    expect(comp.field_type).to eq('text')
    expect(result[:report]['custom_field'][:picklist_without_options_became_text]).to eq(1)
    expect(result[:errors]).to be_empty
  end

  it 'promotes a last name into the NOT NULL first_name without duplicating it' do
    load!
    contact = company.contacts.find_by(email: 'nofirst@parkview.example')

    expect(contact.first_name).to eq('Nofirst')
    expect(contact.last_name).to be_nil
  end

  it 'links a parent account whose parent loads after it' do
    load!
    parent = company.accounts.find_by(name: 'Parkview Management')
    child = company.accounts.find_by(name: 'Parkview East')

    expect(child.parent_account_id).to eq(parent.id)
  end

  it 'sets the real deal stage without posting to accounting' do
    load!
    won = company.deals.find_by(name: 'Parkview rollout')
    lost = company.deals.find_by(name: 'Parkview east pilot')

    expect(won.stage).to eq('closed_won')
    expect(won.won_at).to eq(Time.zone.parse('2026-07-01'))
    expect(won.gl_posted).to be_falsey
    expect(won.value).to eq(24_000)
    expect(won.contact_id).to eq(company.contacts.find_by(email: 'pat@parkview.example').id)

    expect(lost.stage).to eq('closed_lost')
    expect(lost.loss_reason).to eq('Lost to Competition')
    expect(lost.competitor).to eq('Appfolio')
    expect(lost.description).to include('Closed-Lost to Competition')
  end

  it 'writes notes with the CamelCase entity_type the CRM reads' do
    load!
    lead = company.leads.sole
    account = company.accounts.find_by(name: 'Parkview Management')

    expect(Note.for_entity('Lead', lead.id.to_s).sole.content).to include('Discovery', 'Wants rent payments first')
    expect(Note.for_entity('Account', account.id.to_s).count).to eq(1)
  end

  it 'skips a note whose parent module does not exist in DealerTide' do
    result = load!

    expect(result[:report]['note'][:unsupported_parent]).to eq(1)
    expect(Note.where(entity_type: 'Campaign').count).to eq(0)
  end

  it 'updates on a second load instead of duplicating' do
    load!
    data['leads'][0]['status'] = 'contacted'
    result = load!(batch: 'b2')

    expect(result[:errors]).to be_empty
    expect(company.leads.count).to eq(1)
    expect(company.leads.sole.status).to eq('contacted')
    expect(company.accounts.count).to eq(2)
    expect(Note.where(entity_type: 'Lead').count).to eq(1)
  end

  it 'keeps a DealerTide edit made after the load' do
    load!
    lead = company.leads.sole
    lead.update_columns(first_name: 'Joseph', updated_at: 1.hour.from_now)
    data['leads'][0]['first_name'] = 'Joe'
    result = load!(batch: 'b2')

    expect(lead.reload.first_name).to eq('Joseph')
    expect(result[:report]['lead'][:kept_dealertide_edit]).to eq(1)
  end

  it 'takes over a lead status and source the company already has' do
    company.lead_statuses.create!(key: 'dormant', label: 'Dormant', sort_order: 5)
    company.sources.create!(name: 'google ads')
    result = load!

    expect(company.lead_statuses.where(key: 'dormant').count).to eq(1)
    expect(company.sources.where('lower(name) = ?', 'google ads').count).to eq(1)
    expect(result[:report]['lead_status'][:adopted_existing]).to eq(1)
    expect(result[:report]['source'][:adopted_existing]).to eq(1)
  end

  it 'reports a deal stage the company does not have rather than loading onto it' do
    allow(Setting).to receive(:get).and_call_original
    allow(Setting).to receive(:get).with('Company', company.id, 'pipeline_stages', nil)
                                   .and_return([{ 'key' => 'prospecting' }, { 'key' => 'closed_won' }])
    result = load!

    expect(result[:errors].join).to include('closed_lost')
    expect(result[:report]['pipeline_stages'][:missing]).to eq(1)
  end

  it 'reports a Zoho owner with no DealerTide user' do
    data['leads'][0]['owner_email'] = 'gone@renterinsight.com'
    result = load!

    expect(result[:errors].join).to include('no DealerTide user for Zoho owner gone@renterinsight.com')
    expect(company.leads.sole.owner_id).to be_nil
  end

  it 'falls back to a named user when the Zoho owner has no account' do
    data['leads'][0]['owner_email'] = 'gone@renterinsight.com'
    load!(fallback_user: rep)

    expect(company.leads.sole.owner_id).to eq(rep.id)
  end

  describe 'records another tenant already has' do
    let(:other) { create(:company) }

    it 'skips a matching account and everything that hangs off it' do
      other.accounts.create!(name: 'Someone Else', email: 'INFO@parkview.example')
      result = load!(skip_matches_in: other)

      expect(company.accounts.pluck(:name)).to eq(['Parkview East'])
      expect(company.contacts.count).to eq(0)
      expect(company.deals.count).to eq(0)
      expect(Note.where(entity_type: 'Account').count).to eq(0)
      expect(result[:report]['skipped_in_other_tenant']).to include('account' => 1, 'contact' => 2, 'deal' => 2, 'note' => 1)
      expect(result[:skipped].first).to include('A1', "company #{other.id}", 'email')
    end

    it 'matches an account by name, ignoring legal suffixes' do
      other.accounts.create!(name: 'Parkview Management, LLC')
      load!(skip_matches_in: other)

      expect(company.accounts.where(name: 'Parkview Management')).to be_empty
    end

    it 'matches an account by website domain' do
      other.accounts.create!(name: 'Unrelated', website: 'https://www.parkview.example/about')
      load!(skip_matches_in: other)

      expect(company.accounts.where(name: 'Parkview Management')).to be_empty
    end

    it 'skips a lead the other tenant has by phone' do
      other.leads.create!(first_name: 'Joe', phone: '(303) 555-0111')
      load!(skip_matches_in: other)

      expect(company.leads.count).to eq(0)
    end

    it 'does not treat a shared office phone as a match' do
      3.times { |i| other.leads.create!(first_name: "Office #{i}", phone: '303-555-0111') }
      load!(skip_matches_in: other)

      expect(company.leads.count).to eq(1)
    end

    it 'loads everything when no other tenant is given' do
      other.accounts.create!(name: 'Parkview Management', email: 'info@parkview.example')
      load!

      expect(company.accounts.count).to eq(2)
    end
  end

  describe 'deal stages' do
    let(:zoho_pipeline) do
      [{ 'key' => 'gartner_ppl_lead', 'name' => 'Gartner PPL Lead', 'probability' => 5, 'order' => 0, 'active' => true },
       { 'key' => 'closed_won', 'name' => 'Closed Won', 'probability' => 100, 'order' => 1, 'active' => true },
       { 'key' => 'closed_lost', 'name' => 'Closed Lost', 'probability' => 0, 'order' => 2, 'active' => true }]
    end

    before do
      data['reference']['deal_stage_keys'] = %w[gartner_ppl_lead closed_won closed_lost]
      data['reference']['pipeline_stages'] = zoho_pipeline
    end

    it 'writes the bundle pipeline on a company with no deals of its own' do
      result = load!

      expect(Setting.get('Company', company.id, 'pipeline_stages', nil).map { |s| s['key'] })
        .to eq(%w[gartner_ppl_lead closed_won closed_lost])
      expect(result[:report]['pipeline_stages']).to include(written: 3, verified: 3)
      expect(company.deals.pluck(:stage)).to contain_exactly('closed_won', 'closed_lost')
    end

    it 'leaves the pipeline of a company that already has deals' do
      acct = company.accounts.create!(name: 'Own customer')
      company.deals.create!(name: 'Own deal', account: acct, stage: 'prospecting', value: 0)
      result = load!

      expect(Setting.get('Company', company.id, 'pipeline_stages', nil)).to be_nil
      expect(result[:report]['pipeline_stages'][:written]).to eq(0)
    end

    it "with pipeline: 'merge' writes the stages and keeps the one its own deal sits in" do
      acct = company.accounts.create!(name: 'Own customer')
      own = company.deals.create!(name: 'Own deal', account: acct, stage: 'negotiation', value: 0)
      result = load!(pipeline: 'merge')

      keys = Setting.get('Company', company.id, 'pipeline_stages', nil).map { |s| s['key'] }
      expect(keys).to eq(%w[gartner_ppl_lead negotiation closed_won closed_lost])
      expect(result[:report]['pipeline_stages']).to include(kept_in_use: 1)
      expect(own.reload.stage).to eq('negotiation')
      expect(company.deals.where.not(id: own.id).pluck(:stage)).to contain_exactly('closed_won', 'closed_lost')
    end
  end

  it 'keeps a phone with an extension, moving the extension to the notes' do
    data['contacts'][0]['phone'] = '(724) 283-5618 x4'
    result = load!

    pat = company.contacts.find_by!(email: 'pat@parkview.example')
    expect(pat.phone.gsub(/\D/, '')).to end_with('7242835618')
    expect(pat.notes).to include('Phone extension: 4')
    expect(result[:report]['phone_extension_to_notes']['Contact']).to eq(1)
  end

  it 'keeps a record whose phone is not a number at all, with the phone in its notes' do
    data['contacts'][0]['phone'] = 'call the office'
    load!

    pat = company.contacts.find_by!(email: 'pat@parkview.example')
    expect(pat.phone).to be_nil
    expect(pat.notes).to include('Phone from Zoho (not a valid number): call the office')
  end

  describe 'activities' do
    include ActiveJob::TestHelper

    before do
      data['activities'] = [
        { 'zoho_id' => 'E1', 'kind' => 'meeting', 'target_module' => 'Contacts', 'target_zoho_id' => 'C1',
          'subject' => 'Demo with Pat', 'start' => '2023-03-01T17:00:00Z', 'end' => '2023-03-01T18:00:00Z',
          'location' => 'Zoom', 'done' => true, 'owner_email' => 'rep@renterinsight.com',
          'created_at' => '2023-02-20T12:00:00Z' },
        { 'zoho_id' => 'K1', 'kind' => 'call', 'target_module' => 'Accounts', 'target_zoho_id' => 'A1',
          'subject' => 'Outgoing call', 'start' => '2023-02-13T23:11:44Z', 'duration_minutes' => 4,
          'direction' => 'outbound', 'phone' => '+13035550100', 'done' => true, 'created_at' => '2023-02-13T23:11:59Z' },
        { 'zoho_id' => 'T1', 'kind' => 'task', 'target_module' => 'Leads', 'target_zoho_id' => 'L1',
          'subject' => 'Send pricing', 'due' => '2023-04-01', 'done' => false, 'zoho_status' => 'Not Started',
          'created_at' => '2023-03-20T12:00:00Z' },
        { 'zoho_id' => 'K2', 'kind' => 'call', 'target_module' => 'Deals', 'target_zoho_id' => 'D1',
          'subject' => 'Missed call', 'direction' => 'inbound', 'missed' => true, 'done' => true,
          'created_at' => '2023-05-01T12:00:00Z' }
      ]
    end

    it 'loads them onto their records as history' do
      load!

      meeting = ContactActivity.sole
      expect(meeting).to have_attributes(activity_type: 'meeting', status: 'completed', meeting_location: 'Zoom',
                                         remind_customer: false, send_calendar_invite: false)
      expect(meeting.created_at).to eq(Time.zone.parse('2023-02-20T12:00:00Z'))
      expect(AccountActivity.sole).to have_attributes(activity_type: 'call', call_direction: 'outbound', duration_minutes: 4)
      expect(DealActivity.sole).to have_attributes(call_outcome: 'no_answer')
      task = Activity.where(activity_type: 'lead_activity_task').sole
      expect(task.description).to include('Send pricing', 'Still open in Zoho (Not Started)')
    end

    it 'sends no invite, text or notification to anyone' do
      expect { load! }.not_to have_enqueued_job
      expect(Notification.count).to eq(0)
    end

    it 'does not load them twice' do
      load!
      result = load!(batch: 'b2')

      expect(ContactActivity.count + AccountActivity.count + DealActivity.count).to eq(3)
      expect(result[:report]['activity'][:already_loaded]).to eq(4)
    end

    it 'skips activities of a record another tenant has' do
      other = create(:company)
      other.accounts.create!(name: 'Elsewhere', email: 'info@parkview.example')
      load!(skip_matches_in: other)

      expect(AccountActivity.count + ContactActivity.count + DealActivity.count).to eq(0)
      expect(Activity.where(activity_type: 'lead_activity_task').count).to eq(1)
    end
  end

  describe 'files' do
    let(:bytes) { '%PDF-1.4 license agreement' }
    let(:checksum) { Base64.strict_encode64(Digest::MD5.digest(bytes)) }

    before do
      ActiveStorage::Blob.service.upload('zoho-import/F1', StringIO.new(bytes), checksum: checksum)
      data['files'] = [
        { 'zoho_id' => 'F1', 'target_module' => 'Accounts', 'target_zoho_id' => 'A1',
          'filename' => 'License Agreement.pdf', 'byte_size' => bytes.bytesize, 'checksum' => checksum,
          'content_type' => 'application/pdf', 'key' => 'zoho-import/F1',
          'owner_email' => 'rep@renterinsight.com', 'created_at' => '2023-06-06T12:00:00Z' },
        { 'zoho_id' => 'F2', 'target_module' => 'Leads', 'target_zoho_id' => 'L1',
          'filename' => 'missing.pdf', 'byte_size' => 1, 'checksum' => 'x', 'content_type' => 'application/pdf',
          'key' => 'zoho-import/F2' }
      ]
    end

    it 'attaches an uploaded file to its record, keeping the Zoho date and the record unchanged' do
      result = load!
      acct = company.accounts.find_by!(name: 'Parkview Management')

      file = acct.files.sole
      expect(file.filename.to_s).to eq('License Agreement.pdf')
      expect(file.download).to eq(bytes)
      expect(file.blob.metadata).to include('origin' => 'zoho', 'original_created_at' => '2023-06-06T12:00:00Z',
                                            'uploaded_by_id' => rep.id.to_s)
      expect(result[:report]['file']).to include(attached: 1, object_missing: 1)
      expect(company.leads.sole.files).to be_empty
    end

    it 'does not attach twice or count the record as edited on a second load' do
      load!
      result = load!(batch: 'b2')

      expect(company.accounts.find_by!(name: 'Parkview Management').files.count).to eq(1)
      expect(result[:report]['file'][:already_loaded]).to eq(1)
      expect(result[:edited]).to be_empty
    end
  end
end
