# frozen_string_literal: true

require 'rails_helper'
require 'csv'

# Coverage for the export hardening added alongside ImportExport::ExportPolicy:
# tenant-gated formats, curated fields, the row cap, and the per-row watermark.
RSpec.describe ImportExport::ExportPolicy do
  let(:company) { Company.create!(name: "ExportPolicy Co #{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "export-#{SecureRandom.hex(4)}@example.com",
      password: 'password123',
      first_name: 'Export',
      last_name: 'User',
      company_id: company.id
    )
  end

  def set_settings(overrides)
    Setting.set(described_class::SETTING_SCOPE, company.id, described_class::SETTING_KEY, overrides)
  end

  describe 'format gating' do
    it 'withholds JSON by default' do
      expect(described_class.allowed_formats(company)).to contain_exactly('csv', 'xlsx')
      expect(described_class.format_allowed?(company, 'json')).to be(false)
      expect(described_class.json_allowed?(company)).to be(false)
    end

    it 'offers JSON once the tenant flag is on' do
      set_settings('allow_json' => true)

      expect(described_class.allowed_formats(company)).to include('json')
      expect(described_class.format_allowed?(company, 'json')).to be(true)
    end

    it 'always allows the human formats' do
      set_settings('allow_json' => false)

      expect(described_class.format_allowed?(company, 'csv')).to be(true)
      expect(described_class.format_allowed?(company, 'xlsx')).to be(true)
    end
  end

  describe 'tenant overrides' do
    it 'merges over the platform defaults and ignores unknown keys' do
      set_settings('daily_export_limit' => 10, 'nonsense' => 'ignored')

      settings = described_class.settings_for(company)
      expect(settings['daily_export_limit']).to eq(10)
      expect(settings['max_export_rows']).to eq(described_class::DEFAULTS['max_export_rows'])
      expect(settings).not_to have_key('nonsense')
    end
  end

  describe 'field curation' do
    it 'excludes scoring and syndication internals' do
      %w[health_score health_score_updated_at social_intent social_post_id
         champion_salesforce_id champion_status last_activity_scored_at].each do |key|
        expect(described_class.excluded_field?(key)).to be(true), "expected #{key} to be excluded"
      end
    end

    it 'keeps the tenant\'s own business fields' do
      %w[first_name last_name email phone city state notes budget_range].each do |key|
        expect(described_class.excluded_field?(key)).to be(false), "expected #{key} to be allowed"
      end
    end

    it 'strips excluded keys from a requested field list' do
      keys = described_class.filter_keys(%w[first_name health_score champion_status email])
      expect(keys).to eq(%w[first_name email])
    end

    it 'keeps them out of the field list the export builder is offered' do
      fields = ImportExport::ModuleRegistry.fields_for('leads', company_id: company.id, for_export: true)
      keys = fields.map { |f| f[:key] }

      expect(keys).to include('first_name', 'email')
      expect(keys).not_to include('health_score', 'champion_status', 'social_intent')
    end

    it 'leaves the import field list untouched' do
      fields = ImportExport::ModuleRegistry.fields_for('leads', company_id: company.id, for_import: true)
      expect(fields.map { |f| f[:key] }).to include('first_name')
    end
  end

  describe 'rate limiting' do
    def create_job(created_at: Time.current)
      ExportJob.create!(
        company_id: company.id, user_id: user.id, module_type: 'leads',
        format: 'csv', status: 'completed', created_at: created_at
      )
    end

    it 'counts only the trailing 24 hours' do
      create_job(created_at: 30.hours.ago)
      create_job

      expect(described_class.used_today(company, user)).to eq(1)
    end

    it 'blocks once the limit is reached' do
      set_settings('daily_export_limit' => 2)
      2.times { create_job }

      expect(described_class.remaining_today(company, user)).to eq(0)
      expect(described_class.rate_limited?(company, user)).to be(true)
    end

    it 'treats 0 as unlimited' do
      set_settings('daily_export_limit' => 0)
      5.times { create_job }

      expect(described_class.remaining_today(company, user)).to be_nil
      expect(described_class.rate_limited?(company, user)).to be(false)
    end
  end
end

RSpec.describe ImportExport::Exporter do
  let(:company) { Company.create!(name: "Exporter Co #{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "exporter-#{SecureRandom.hex(4)}@example.com",
      password: 'password123',
      first_name: 'Ex',
      last_name: 'Porter',
      company_id: company.id
    )
  end

  before do
    3.times do |i|
      Lead.create!(company_id: company.id, first_name: "Lead#{i}", last_name: 'Test',
                   email: "lead#{i}-#{SecureRandom.hex(3)}@example.com", status: 'new')
    end
  end

  def build_job(format: 'csv', fields: %w[first_name last_name email])
    ExportJob.create!(
      company_id: company.id, user_id: user.id, module_type: 'leads',
      format: format, selected_fields: fields, status: 'pending',
      watermark_token: ImportExport::ExportPolicy.new_watermark_token
    )
  end

  it 'stamps every CSV row with the export reference' do
    job = build_job
    described_class.new(job).process!
    job.reload

    expect(job.status).to eq('completed')
    rows = CSV.read(job.file_url, headers: true)
    expect(rows.headers).to include(ImportExport::Exporter::WATERMARK_LABEL)
    expect(rows.size).to eq(3)
    expect(rows.map { |r| r[ImportExport::Exporter::WATERMARK_LABEL] }.uniq).to eq([job.watermark_token])
  end

  it 'stamps every JSON record with the export reference' do
    job = build_job(format: 'json')
    described_class.new(job).process!
    job.reload

    data = JSON.parse(File.read(job.file_url))
    expect(data.size).to eq(3)
    expect(data.map { |r| r[ImportExport::Exporter::WATERMARK_LABEL] }.uniq).to eq([job.watermark_token])
  end

  it 'drops an excluded field even when the request names it directly' do
    job = build_job(fields: %w[first_name health_score])
    described_class.new(job).process!
    job.reload

    expect(CSV.read(job.file_url, headers: true).headers).not_to include('Health score')
  end

  it 'refuses rather than truncating when the row cap is exceeded' do
    Setting.set(ImportExport::ExportPolicy::SETTING_SCOPE, company.id,
                ImportExport::ExportPolicy::SETTING_KEY, { 'max_export_rows' => 2 })
    job = build_job

    expect { described_class.new(job).process! }.not_to raise_error
    job.reload

    expect(job.status).to eq('failed')
    expect(job.error_message).to match(/3 rows, above the 2 row limit/)
    expect(job.file_url).to be_nil
  end
end
