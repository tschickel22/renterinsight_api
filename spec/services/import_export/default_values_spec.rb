# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'
require 'csv'

# Coverage for ImportJob options['default_values'] — per-import attribute
# defaults that fill in fields the CSV doesn't map (e.g. leads.status='new'
# so imported leads land in the active list).
RSpec.describe 'Import engine — default_values for unmapped fields', :aggregate_failures do
  let(:company) { Company.create!(name: 'DefaultValues Co') }
  let(:user) do
    User.create!(
      email: "defaults-user-#{SecureRandom.hex(4)}@example.com",
      password: 'password123',
      first_name: 'Importer',
      last_name: 'User'
    )
  end

  # Tempfile unlinks its backing file when the object is garbage collected.
  # The importer resolves source_file_url through S3Helper, which only
  # short-circuits to a local path while that file still exists — so hold a
  # reference for the life of the example, or the import falls through to
  # real S3 and dies on NoSuchKey (intermittently, per GC timing).
  let(:tempfiles) { [] }

  def build_csv(headers, *rows)
    file = Tempfile.new(['defaults', '.csv'])
    tempfiles << file
    CSV.open(file.path, 'w') do |csv|
      csv << headers
      rows.each { |r| csv << r }
    end
    file.path
  end

  def build_job(csv_path, column_mapping:, default_values: nil)
    options = {}
    options['default_values'] = default_values if default_values
    ImportJob.create!(
      company:            company,
      user:               user,
      module_type:        'leads',
      status:             'pending',
      source_filename:    'defaults.csv',
      source_file_url:    csv_path,
      duplicate_strategy: 'skip',
      column_mapping:     column_mapping,
      options:            options
    )
  end

  it 'fills blank attrs from default_values when the CSV omits the column' do
    csv_path = build_csv(
      ['First Name', 'Last Name', 'Email'],
      ['Ada', 'Lovelace', "ada-#{SecureRandom.hex(3)}@example.com"]
    )
    job = build_job(
      csv_path,
      column_mapping: { 'First Name' => 'first_name', 'Last Name' => 'last_name', 'Email' => 'email' },
      default_values: { 'status' => 'new' }
    )

    ImportExport::Importer.new(job).process!

    expect(job.reload.success_count).to eq(1)
    lead = company.leads.order(:created_at).last
    expect(lead.status).to eq('new')
  end

  it 'lets an actual CSV value beat the default' do
    csv_path = build_csv(
      ['First Name', 'Last Name', 'Email', 'Status'],
      ['Grace', 'Hopper', "grace-#{SecureRandom.hex(3)}@example.com", 'contacted']
    )
    job = build_job(
      csv_path,
      column_mapping: {
        'First Name' => 'first_name', 'Last Name' => 'last_name',
        'Email'      => 'email',      'Status'    => 'status'
      },
      default_values: { 'status' => 'new' }
    )

    ImportExport::Importer.new(job).process!

    expect(job.reload.success_count).to eq(1)
    lead = company.leads.order(:created_at).last
    expect(lead.status).to eq('contacted')
  end

  it 'silently ignores unknown field keys in default_values' do
    csv_path = build_csv(
      ['First Name', 'Last Name', 'Email'],
      ['Hedy', 'Lamarr', "hedy-#{SecureRandom.hex(3)}@example.com"]
    )
    job = build_job(
      csv_path,
      column_mapping: { 'First Name' => 'first_name', 'Last Name' => 'last_name', 'Email' => 'email' },
      default_values: { 'totally_made_up_attr' => 'whatever', 'status' => 'new' }
    )

    expect { ImportExport::Importer.new(job).process! }.not_to raise_error

    expect(job.reload.status).to eq('completed')
    expect(job.success_count).to eq(1)
    lead = company.leads.order(:created_at).last
    # Known key still applied; unknown silently dropped (no error, no attr set).
    expect(lead.status).to eq('new')
    expect(lead).not_to respond_to(:totally_made_up_attr)
  end
end
