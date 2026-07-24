# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'
require 'csv'

# Coverage for order-independent ("deferred") import linking. When a child
# record (e.g. a service ticket) references a parent (e.g. a vehicle) that
# hasn't been imported yet, the importer records a PendingImportLink and
# back-fills the foreign key once the parent is imported -- in the same run or
# a later upload session.
RSpec.describe 'Import engine -- deferred linking', :aggregate_failures do
  let(:company) { Company.create!(name: "Deferred Co #{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(
      email: "deferred-#{SecureRandom.hex(4)}@example.com",
      password: 'password123',
      first_name: 'Importer',
      last_name: 'User'
    )
  end

  # A fully-valid manufactured-home Vehicle (satisfies all presence/inclusion
  # validations). stock_number is the lookup key the children reference.
  def make_vehicle(stock_number:)
    company.vehicles.create!(
      listing_type:  'manufactured_home',
      status:        'available',
      year:          2024,
      make:          'Clayton',
      model:         'The Edge',
      serial_number: "SN-#{stock_number}",
      bedrooms:      3,
      bathrooms:     2,
      stock_number:  stock_number
    )
  end

  # Hold Tempfile references for the life of the example — a collected
  # Tempfile unlinks its backing file, and S3Helper only short-circuits to a
  # local path while that file exists (otherwise the import hits real S3).
  let(:tempfiles) { [] }

  def run_job(module_type:, headers:, rows:, mapping:, strategy: 'create_new', default_values: {})
    file = Tempfile.new(["imp_#{module_type}", '.csv'])
    tempfiles << file
    CSV.open(file.path, 'w') do |csv|
      csv << headers
      rows.each { |r| csv << r }
    end

    job = ImportJob.create!(
      company:            company,
      user:               user,
      module_type:        module_type,
      status:             'pending',
      source_filename:    "#{module_type}.csv",
      source_file_url:    file.path,
      duplicate_strategy: strategy,
      column_mapping:     mapping,
      options:            { 'default_values' => default_values }
    )
    ImportExport::Importer.new(job).process!
    job.reload
  end

  # Service tickets validate presence of status/priority at the RowValidator
  # stage (before the model's set_defaults callback runs), so a real import
  # supplies them as per-import defaults. Mirror that here.
  TICKET_DEFAULTS = { 'status' => 'open', 'priority' => 'medium' }.freeze

  it 'records a pending link and back-fills the FK when the parent is imported AFTER the child' do
    # 1. Import a service ticket referencing a vehicle (by stock #) that does
    #    not exist yet. Vehicles are never auto-created -> pure deferral path.
    ticket_job = run_job(
      module_type: 'service_tickets',
      headers: ['Title', 'Description', 'Vehicle Stock'],
      rows:    [['Leaky faucet', 'Master bath faucet drips', 'STK-9000']],
      mapping: {
        'Title' => 'title', 'Description' => 'description', 'Vehicle Stock' => 'vehicle_stock'
      },
      default_values: TICKET_DEFAULTS
    )

    # Surface why a row failed, if it did, so the fixture problem is visible.
    expect(ticket_job.status).to(eq('completed'), -> { "job status=#{ticket_job.status} errors=#{ticket_job.error_log.inspect}" })
    ticket = company.service_tickets.find_by(title: 'Leaky faucet')
    expect(ticket).to(be_present, -> { "no ticket created. error_log=#{ticket_job.error_log.inspect}" })
    expect(ticket.vehicle_id).to be_nil # not linked yet -- parent missing

    link = PendingImportLink.pending.find_by(
      company_id: company.id, entity_type: 'ServiceTicket', entity_id: ticket.id
    )
    expect(link).to be_present
    expect(link.parent_model).to eq('Vehicle')
    expect(link.target_column).to eq('vehicle_id')
    expect(link.lookup_value).to eq('STK-9000')

    # 2. The parent vehicle appears.
    vehicle = make_vehicle(stock_number: 'STK-9000')
    ImportExport::LinkResolver.new(company).resolve_for_parent!(vehicle)

    # 3. The ticket is now linked and the pending link is resolved.
    expect(ticket.reload.vehicle_id).to eq(vehicle.id)
    expect(link.reload.status).to eq('resolved')
    expect(link.resolved_parent_id).to eq(vehicle.id)
  end

  it 'reconcile_all! resolves outstanding links in a batch' do
    run_job(
      module_type: 'service_tickets',
      headers: ['Title', 'Description', 'Vehicle Stock'],
      rows: [
        ['HVAC check', 'Annual service', 'STK-7777'],
        ['Skirting fix', 'Replace panel', 'STK-7777']
      ],
      mapping: {
        'Title' => 'title', 'Description' => 'description', 'Vehicle Stock' => 'vehicle_stock'
      },
      default_values: TICKET_DEFAULTS
    )

    expect(PendingImportLink.pending.where(company_id: company.id).count).to eq(2)

    vehicle = make_vehicle(stock_number: 'STK-7777')

    resolved = ImportExport::LinkResolver.new(company).reconcile_all!
    expect(resolved).to eq(2)
    expect(PendingImportLink.pending.where(company_id: company.id).count).to eq(0)
    expect(company.service_tickets.where(vehicle_id: vehicle.id).count).to eq(2)
  end

  it 'links inline (no pending link) when the parent already exists, and never clobbers it' do
    existing = make_vehicle(stock_number: 'STK-EXIST')

    run_job(
      module_type: 'service_tickets',
      headers: ['Title', 'Description', 'Vehicle Stock'],
      rows:    [['Punch list', 'Final walkthrough items', 'STK-EXIST']],
      mapping: {
        'Title' => 'title', 'Description' => 'description', 'Vehicle Stock' => 'vehicle_stock'
      },
      default_values: TICKET_DEFAULTS
    )

    ticket = company.service_tickets.find_by(title: 'Punch list')
    expect(ticket.vehicle_id).to eq(existing.id)
    expect(PendingImportLink.where(company_id: company.id, entity_id: ticket.id)).to be_empty
  end
end
