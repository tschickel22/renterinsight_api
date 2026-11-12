# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# QuickBooks customers and vendors find the DealerTide record they already
# are (ListMatcher): by QuickBooks id, email, phone, then name with business
# endings ignored; customers among contacts, then open leads, which convert.
# More than one possible match waits for a person to pick. Posting also turns
# off the older QuickBooks sync, and rolling back turns it on again.
RSpec.describe Accounting::QboMigration::ListMatcher do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Prairie-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Keeper',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let!(:books) { build_dealer_books(company) }

  around { |ex| with_qbo_fixture { ex.run } }
  before { stub_claude(company) }

  def start
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER)
    Accounting::QboMigration::Wizard.new(import)
  end

  def row(wizard, kind, external_id)
    wizard.list_rows(kind).find { |r| r[:external_id] == external_id }
  end

  def vendor(name, **attrs)
    company.vendors.create!(name: name, vendor_type: 'supplier', status: 'active', **attrs)
  end

  def lead(first, last, **attrs)
    company.leads.create!(first_name: first, last_name: last, location_id: books[:location].id, **attrs)
  end

  describe '.normalize_name' do
    it 'ignores case, punctuation and business endings' do
      names = ['Clayton Supply Co', 'Clayton Supply Co.', 'CLAYTON SUPPLY, INC.', 'Clayton Supply Company LLC', 'clayton supply']
      expect(names.map { |n| described_class.normalize_name(n) }.uniq).to eq(['clayton supply'])
      expect(described_class.normalize_name('The Lakeview Estates, L.L.C.')).to eq('lakeview estates')
      expect(described_class.normalize_name('Smith & Sons')).to eq('smith and sons')
      expect(described_class.normalize_name('Co')).to eq('co')
    end

    it 'reads phones as their ten digits' do
      expect(described_class.normalize_phone('+1 (336) 555-0150')).to eq('3365550150')
      expect(described_class.normalize_phone('336.555.0150')).to eq('3365550150')
      expect(described_class.normalize_phone('555-0150')).to be_nil
    end
  end

  describe 'matching' do
    it 'links vendors by name with endings ignored and by phone, and leaves the rest new' do
      clayton = vendor('Clayton Supply, Inc.')
      triad = vendor('Triad Freight', phone: '336.555.0150')
      wizard = start

      expect(row(wizard, 'vendors', '201')).to include(status: 'link', reason: 'name')
      expect(row(wizard, 'vendors', '201')[:match]).to include(type: 'vendor', id: clayton.id)
      expect(row(wizard, 'vendors', '202')).to include(status: 'link', reason: 'phone')
      expect(row(wizard, 'vendors', '202')[:match][:id]).to eq(triad.id)
      expect(row(wizard, 'vendors', '205')).to include(status: 'new', match: nil)
    end

    it 'waits for a person when two vendors could be the one' do
      a = vendor('Xcel Energy')
      vendor('XCEL ENERGY INC')
      wizard = start

      r = row(wizard, 'vendors', '204')
      expect(r[:status]).to eq('needs_choice')
      expect(r[:candidates].size).to eq(2)
      expect(wizard.steps[:lists]).to include(done: false, needs_choice: 1)
      expect(wizard.blockers.join).to include('more than one possible match')

      wizard.update_list_choices!([{ 'kind' => 'vendors', 'external_id' => '204', 'action' => 'link', 'type' => 'vendor', 'id' => a.id }])
      wizard = Accounting::QboMigration::Wizard.new(wizard.import.reload)
      expect(row(wizard, 'vendors', '204')).to include(status: 'link', reason: 'chosen')
      expect(wizard.steps[:lists][:done]).to be(true)
    end

    it 'finds customers among contacts by name and phone, then open leads by email' do
      diane = company.contacts.create!(first_name: 'Diane', last_name: 'Foster', email: 'dfoster@other.example.com')
      marcus = company.contacts.create!(first_name: 'M.', last_name: 'Hill', phone: '720-555-0199')
      jake = lead('Jake', 'Thompson', email: 'Jake.Thompson@example.com')
      wizard = start

      expect(row(wizard, 'customers', '104')).to include(status: 'link', reason: 'name')
      expect(row(wizard, 'customers', '104')[:match][:id]).to eq(diane.id)
      expect(row(wizard, 'customers', '106')).to include(status: 'link', reason: 'phone')
      expect(row(wizard, 'customers', '106')[:match][:id]).to eq(marcus.id)
      expect(row(wizard, 'customers', '101')).to include(status: 'convert_lead', reason: 'email')
      expect(row(wizard, 'customers', '101')[:match]).to include(type: 'lead', id: jake.id)
    end

    it 'asks about a lead found by name alone' do
      lead('Robert', 'Kline')
      wizard = start
      expect(row(wizard, 'customers', '103')).to include(status: 'needs_choice', reason: 'name')
    end

    it 'refuses a choice for something not in the switch or of the wrong kind' do
      v = vendor('Somebody Else')
      wizard = start
      expect { wizard.update_list_choices!([{ 'kind' => 'vendors', 'external_id' => '999', 'action' => 'new' }]) }
        .to raise_error(Accounting::QboMigration::Error, /not in this switch/)
      expect { wizard.update_list_choices!([{ 'kind' => 'customers', 'external_id' => '101', 'action' => 'link', 'type' => 'vendor', 'id' => v.id }]) }
        .to raise_error(Accounting::QboMigration::Error, /cannot be matched/)
    end

    it 'forgets a choice with auto' do
      vendor('Mobile Home Parts Depot')
      wizard = start
      wizard.update_list_choices!([{ 'kind' => 'vendors', 'external_id' => '205', 'action' => 'new' }])
      expect(row(Accounting::QboMigration::Wizard.new(wizard.import.reload), 'vendors', '205')).to include(status: 'new', reason: 'chosen')
      wizard = Accounting::QboMigration::Wizard.new(wizard.import.reload)
      wizard.update_list_choices!([{ 'kind' => 'vendors', 'external_id' => '205', 'action' => 'auto' }])
      expect(row(Accounting::QboMigration::Wizard.new(wizard.import.reload), 'vendors', '205')).to include(status: 'link', reason: 'name')
    end
  end

  describe 'posting' do
    it 'links, converts the lead, creates only what is new, and turns the old QuickBooks sync off until rollback' do
      clayton = vendor('Clayton Supply Co.')
      diane = company.contacts.create!(first_name: 'Diane', last_name: 'Foster')
      jake = lead('Jake', 'Thompson', email: 'jake.thompson@example.com')
      kline = lead('Robert', 'Kline')
      company.update_column(:quickbooks_settings, { 'auto_sync' => true,
                                                    'entities' => { 'invoices' => { 'enabled' => true, 'sync_direction' => 'to_qb' },
                                                                    'vendors' => { 'enabled' => false } } })
      location = books[:location]
      location.update_column(:quickbooks_settings, { 'entities' => { 'payments' => { 'enabled' => true } } })

      wizard = start
      wizard.update_list_choices!([{ 'kind' => 'customers', 'external_id' => '103', 'action' => 'new' }])
      wizard = drive_to_ready(Accounting::QboMigration::Wizard.new(wizard.import.reload), books)

      sync = wizard.preview_json[:quickbooks_sync]
      expect(sync[:on]).to be(true)
      expect(sync[:places].map { |p| [p[:type], p[:entities]] }).to contain_exactly(['company', ['invoices']], ['location', ['payments']])

      vendors_before = company.vendors.count
      new_vendors = wizard.list_rows('vendors').count { |r| r[:status] == 'new' }
      results = Accounting::QboMigration::Poster.new(wizard, user).post!

      expect(clayton.reload.quickbooks_id).to eq('201')
      expect(diane.reload.quickbooks_id).to eq('104')
      expect(company.vendors.count).to eq(vendors_before + new_vendors)
      expect(results[:customers][:converted_leads]).to eq(1)

      jake.reload
      expect(jake.is_converted).to be(true)
      jake_contact = company.contacts.find_by(quickbooks_id: '101')
      expect(jake_contact.account_id).to eq(jake.converted_account_id)
      expect(kline.reload.is_converted).to be_falsey
      expect(company.contacts.where(quickbooks_id: '103').count).to eq(1)

      settings = company.reload.quickbooks_settings
      expect(settings['auto_sync']).to be(false)
      expect(settings.dig('entities', 'invoices', 'enabled')).to be(false)
      expect(location.reload.quickbooks_settings.dig('entities', 'payments', 'enabled')).to be(false)

      Accounting::QboMigration::Rollback.new(Accounting::QboMigration::Wizard.new(wizard.import.reload)).run!(user)
      settings = company.reload.quickbooks_settings
      expect(settings['auto_sync']).to be(true)
      expect(settings.dig('entities', 'invoices', 'enabled')).to be(true)
      expect(location.reload.quickbooks_settings.dig('entities', 'payments', 'enabled')).to be(true)
      expect(jake.reload.is_converted).to be(true)
    end
  end
end
