# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'
require 'csv'

# Coverage for the import-engine Tag support added in TAGGABLE_MODULES /
# FieldMapper / ImportExport::Importer. Tests the three layers separately
# (registry plumbing, header auto-mapping, end-to-end import + dedup).
RSpec.describe 'Import engine — tag column support' do
  # Hold Tempfile references for the life of the example — a collected
  # Tempfile unlinks its backing file, and S3Helper only short-circuits to a
  # local path while that file exists (otherwise the import hits real S3).
  let(:tempfiles) { [] }
  let(:company) { Company.create!(name: 'TagSpec Co') }
  let(:user) do
    User.create!(
      email: "tagspec-user-#{SecureRandom.hex(4)}@example.com",
      password: 'password123',
      first_name: 'Importer',
      last_name: 'User'
    )
  end

  # ─── 1. ModuleRegistry exposes 'tags' for taggable modules only ──────────
  describe 'ModuleRegistry.fields_for' do
    %w[accounts contacts leads deals quotes].each do |mod|
      it "includes a 'tags' field for #{mod} when for_import: true" do
        fields = ImportExport::ModuleRegistry.fields_for(mod, company_id: company.id, for_import: true)
        tag_field = fields.find { |f| f[:key] == 'tags' }
        expect(tag_field).to be_present
        expect(tag_field[:source]).to eq('tag')
        expect(tag_field[:required]).to eq(false)
        expect(tag_field[:placeholder]).to match(/pipe.*comma/i)
      end
    end

    it 'omits the tags field for non-taggable modules (parts)' do
      fields = ImportExport::ModuleRegistry.fields_for('parts', company_id: company.id, for_import: true)
      expect(fields.find { |f| f[:key] == 'tags' }).to be_nil
    end

    it 'omits the tags field when for_import is false (export view)' do
      fields = ImportExport::ModuleRegistry.fields_for('leads', company_id: company.id, for_import: false)
      expect(fields.find { |f| f[:key] == 'tags' }).to be_nil
    end
  end

  # ─── 2. FieldMapper auto-suggests 'tags' for common header names ─────────
  describe 'ImportExport::FieldMapper' do
    let(:fields) { ImportExport::ModuleRegistry.fields_for('leads', company_id: company.id, for_import: true) }

    ['Tags', 'tag', 'Labels', 'label'].each do |header|
      it "auto-maps '#{header}' header to the tags field" do
        result = ImportExport::FieldMapper.new([header], fields).call
        expect(result[:suggested_mapping][header]).to eq('tags')
      end
    end

    it 'does not steal a header that clearly belongs to another field' do
      result = ImportExport::FieldMapper.new(['Email'], fields).call
      expect(result[:suggested_mapping]['Email']).to eq('email')
    end
  end

  # ─── 3. End-to-end import: tag parsing, find-or-create, assignment ───────
  describe 'ImportExport::Importer with a Tags column', :aggregate_failures do
    let(:csv_path) do
      file = Tempfile.new(['tag_import', '.csv'])
      tempfiles << file
      CSV.open(file.path, 'w') do |csv|
        csv << ['First Name', 'Last Name', 'Email', 'Tags']
        csv << ['Ada',  'Lovelace', "ada-#{SecureRandom.hex(3)}@example.com",  'VIP|Hot Lead, Trade Show']
      end
      file.path
    end

    let(:job) do
      ImportJob.create!(
        company:           company,
        user:              user,
        module_type:       'leads',
        status:            'pending',
        source_filename:   'tag_import.csv',
        source_file_url:   csv_path,
        duplicate_strategy: 'skip',
        column_mapping: {
          'First Name' => 'first_name',
          'Last Name'  => 'last_name',
          'Email'      => 'email',
          'Tags'       => 'tags'
        }
      )
    end

    it 'creates the lead, three new tags, and three tag assignments' do
      expect { ImportExport::Importer.new(job).process! }
        .to change { company.leads.count }.by(1)
        .and change { company.tags.count }.by(3)
        .and change { TagAssignment.where(company_id: company.id).count }.by(3)

      lead = company.leads.order(:created_at).last
      expect(lead.tags.pluck(:name)).to match_array(%w[VIP Hot\ Lead Trade\ Show])
      expect(job.reload.status).to eq('completed')
      expect(job.success_count).to eq(1)
    end

    context 'case-insensitive dedup against existing tags' do
      before do
        company.tags.create!(name: 'VIP', color: '#6B7280', is_active: true)
      end

      let(:csv_path) do
        file = Tempfile.new(['tag_dedup', '.csv'])
        tempfiles << file
        CSV.open(file.path, 'w') do |csv|
          csv << ['First Name', 'Last Name', 'Email', 'Tags']
          csv << ['Grace', 'Hopper', "grace-#{SecureRandom.hex(3)}@example.com", 'vip']
        end
        file.path
      end

      it 'reuses the existing VIP tag without creating a duplicate' do
        expect { ImportExport::Importer.new(job).process! }
          .to change { company.leads.count }.by(1)
          .and change { company.tags.count }.by(0)
          .and change { TagAssignment.where(company_id: company.id).count }.by(1)

        lead = company.leads.order(:created_at).last
        expect(lead.tags.count).to eq(1)
        expect(lead.tags.first.name).to eq('VIP')
      end
    end
  end
end
