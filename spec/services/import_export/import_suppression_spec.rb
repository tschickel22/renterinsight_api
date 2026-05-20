# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'
require 'csv'

# Coverage for the per-import side-effect suppression: notifications,
# webhooks, activity logs, and workflow callbacks should NOT fire for
# each imported record. A single summary ActivityLog row is written by
# the importer after the run completes in place of the per-record entries.
RSpec.describe 'Import engine — side-effect suppression', :aggregate_failures do
  let(:company) { Company.create!(name: 'Suppression Co') }
  let(:user) do
    User.create!(
      email: "suppress-user-#{SecureRandom.hex(4)}@example.com",
      password: 'password123',
      first_name: 'Importer',
      last_name: 'User'
    )
  end

  def build_csv
    file = Tempfile.new(['suppress', '.csv'])
    CSV.open(file.path, 'w') do |csv|
      csv << ['First Name', 'Last Name', 'Email']
      csv << ['Ada',  'Lovelace',  "ada-#{SecureRandom.hex(3)}@example.com"]
      csv << ['Grace', 'Hopper',   "grace-#{SecureRandom.hex(3)}@example.com"]
    end
    file.path
  end

  let(:job) do
    ImportJob.create!(
      company:            company,
      user:               user,
      module_type:        'leads',
      status:             'pending',
      source_filename:    'suppress.csv',
      source_file_url:    build_csv,
      duplicate_strategy: 'skip',
      column_mapping: { 'First Name' => 'first_name', 'Last Name' => 'last_name', 'Email' => 'email' }
    )
  end

  it 'sets all four skip flags on every imported record before save' do
    saved = []
    # Capture the runtime values of the flags as Lead#save fires. before_save
    # runs after assign_attributes inside the importer, so the flags must
    # already be set if the suppression contract holds.
    Lead.set_callback(:save, :before, prepend: true) do |record|
      saved << {
        skip_notifications:     record.skip_notifications,
        skip_webhooks:          record.skip_webhooks,
        skip_activity_tracking: record.skip_activity_tracking,
        skip_workflows:         record.skip_workflows
      }
    end

    begin
      ImportExport::Importer.new(job).process!
    ensure
      Lead.reset_callbacks(:save)
      # Re-enable ActivityTrackable's commit hook by reloading the concern.
      # set_callback above only adds a transient callback; reset_callbacks
      # only clears save-level hooks, so the include-time after_*_commit
      # registrations stay intact. Defensive belt-and-braces:
      Lead.include(ActivityTrackable) unless Lead.ancestors.include?(ActivityTrackable)
    end

    expect(saved.size).to eq(2)
    saved.each do |flags|
      expect(flags[:skip_notifications]).to     eq(true)
      expect(flags[:skip_webhooks]).to          eq(true)
      expect(flags[:skip_activity_tracking]).to eq(true)
      expect(flags[:skip_workflows]).to         eq(true)
    end
  end

  it 'suppresses per-record ActivityLog rows and writes a single summary entry' do
    before_count = company.activity_logs.count

    ImportExport::Importer.new(job).process!

    after_count = company.activity_logs.count
    expect(after_count - before_count).to eq(1)

    summary = company.activity_logs.order(:created_at).last
    expect(summary.action).to eq('import')
    expect(summary.module_name).to eq('leads')
    expect(summary.description).to include('Imported 2')
    expect(summary.description).to include('leads')
    expect(summary.metadata['import_job_id']).to eq(job.id)
    expect(summary.metadata['success_count']).to eq(2)
  end

  it 'still writes a summary entry even when zero rows succeed' do
    # Empty file → 0 rows imported, but the job still completes and the
    # summary line goes out so the user has a record of the attempt.
    empty_file = Tempfile.new(['empty', '.csv'])
    CSV.open(empty_file.path, 'w') { |csv| csv << ['First Name', 'Last Name', 'Email'] }
    empty_job = ImportJob.create!(
      company:            company,
      user:               user,
      module_type:        'leads',
      status:             'pending',
      source_filename:    'empty.csv',
      source_file_url:    empty_file.path,
      duplicate_strategy: 'skip',
      column_mapping: { 'First Name' => 'first_name', 'Last Name' => 'last_name', 'Email' => 'email' }
    )

    expect { ImportExport::Importer.new(empty_job).process! }
      .to change { company.activity_logs.count }.by(1)

    expect(company.activity_logs.order(:created_at).last.description).to match(/Imported 0/)
  end
end
