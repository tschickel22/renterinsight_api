# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Audiences::FilterCompiler do
  let(:company) { Company.create!(name: "FC-#{SecureRandom.hex(4)}") }
  let(:other_company) { Company.create!(name: "OC-#{SecureRandom.hex(4)}") }
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }

  def make_lead(co, attrs = {})
    Lead.create!({
      company: co, source: source,
      first_name: "F#{SecureRandom.hex(2)}",
      last_name:  "L#{SecureRandom.hex(2)}",
      email: "lead#{SecureRandom.hex(4)}@e.com",
      status: 'new'
    }.merge(attrs))
  end

  describe 'base relation' do
    it 'returns all leads in company when filter_tree is empty' do
      l1 = make_lead(company)
      _other = make_lead(other_company)
      compiler = described_class.new(company: company, source_type: 'Lead', filter_tree: {})
      expect(compiler.scope.pluck(:id)).to contain_exactly(l1.id)
    end

    it 'enforces tenant isolation — leads from another company never appear' do
      _l1 = make_lead(company)
      l2 = make_lead(other_company)
      compiler = described_class.new(company: company, source_type: 'Lead', filter_tree: {})
      expect(compiler.scope.pluck(:id)).not_to include(l2.id)
    end

    it 'raises CompilationError on bad source_type' do
      compiler = described_class.new(company: company, source_type: 'Bogus', filter_tree: {})
      expect { compiler.scope.to_a }.to raise_error(described_class::CompilationError)
    end
  end

  describe 'leaf operators on Lead' do
    let!(:l_new) { make_lead(company, status: 'new', email: 'alice@example.com') }
    let!(:l_qual) { make_lead(company, status: 'qualified', email: 'bob@otherdomain.com') }

    it 'equals filters by status' do
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'status', 'operator' => 'equals', 'value' => 'qualified' }] }
      ids = described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.pluck(:id)
      expect(ids).to contain_exactly(l_qual.id)
    end

    it 'contains uses ILIKE on email' do
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'email', 'operator' => 'contains', 'value' => 'example' }] }
      ids = described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.pluck(:id)
      expect(ids).to contain_exactly(l_new.id)
    end

    it 'days_since_greater_than finds rows older than N days' do
      old_lead = make_lead(company)
      old_lead.update_columns(created_at: 100.days.ago)

      tree = { 'type' => 'and', 'children' => [{ 'field' => 'created_at', 'operator' => 'days_since_greater_than', 'value' => 90 }] }
      ids = described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.pluck(:id)
      expect(ids).to include(old_lead.id)
      expect(ids).not_to include(l_new.id, l_qual.id)
    end

    it 'AND group applies all conditions' do
      tree = { 'type' => 'and', 'children' => [
        { 'field' => 'status', 'operator' => 'equals', 'value' => 'new' },
        { 'field' => 'email', 'operator' => 'contains', 'value' => 'alice' }
      ] }
      ids = described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.pluck(:id)
      expect(ids).to contain_exactly(l_new.id)
    end

    it 'OR group unions matching ids' do
      tree = { 'type' => 'or', 'children' => [
        { 'field' => 'status', 'operator' => 'equals', 'value' => 'qualified' },
        { 'field' => 'email', 'operator' => 'contains', 'value' => 'alice' }
      ] }
      ids = described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.pluck(:id)
      expect(ids).to contain_exactly(l_new.id, l_qual.id)
    end

    it 'unknown field raises CompilationError' do
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'evil_column', 'operator' => 'equals', 'value' => 'x' }] }
      compiler = described_class.new(company: company, source_type: 'Lead', filter_tree: tree)
      expect { compiler.scope.to_a }.to raise_error(described_class::CompilationError, /Unknown field/)
    end

    it 'unsupported operator raises CompilationError' do
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'status', 'operator' => 'wat', 'value' => 'x' }] }
      compiler = described_class.new(company: company, source_type: 'Lead', filter_tree: tree)
      expect { compiler.scope.to_a }.to raise_error(described_class::CompilationError, /Unsupported operator/)
    end
  end

  describe 'tag operators' do
    let(:hot_tag) { Tag.create!(company: company, name: 'hot', tag_type: 'lead', is_active: true) }
    let(:warm_tag) { Tag.create!(company: company, name: 'warm', tag_type: 'lead', is_active: true) }
    let!(:hot_lead) { make_lead(company, email: 'h@e.com') }
    let!(:cold_lead) { make_lead(company, email: 'c@e.com') }

    before do
      TagAssignment.create!(company: company, tag: hot_tag, entity_type: 'Lead', entity_id: hot_lead.id, assigned_at: Time.current)
    end

    it 'tags_include matches by tag name' do
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'tags', 'operator' => 'tags_include', 'value' => 'hot' }] }
      ids = described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.pluck(:id)
      expect(ids).to contain_exactly(hot_lead.id)
    end

    it 'tags_any_of accepts an array' do
      warm_lead = make_lead(company, email: 'w@e.com')
      TagAssignment.create!(company: company, tag: warm_tag, entity_type: 'Lead', entity_id: warm_lead.id, assigned_at: Time.current)
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'tags', 'operator' => 'tags_any_of', 'value' => ['hot', 'warm'] }] }
      ids = described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.pluck(:id)
      expect(ids).to contain_exactly(hot_lead.id, warm_lead.id)
    end

    it 'tags_exclude removes tagged records' do
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'tags', 'operator' => 'tags_exclude', 'value' => 'hot' }] }
      ids = described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.pluck(:id)
      expect(ids).to contain_exactly(cold_lead.id)
    end
  end

  describe 'exclude_filter_tree' do
    let!(:l_new) { make_lead(company, status: 'new') }
    let!(:l_qual) { make_lead(company, status: 'qualified') }

    it 'removes records matching the exclude tree' do
      include_tree = { 'type' => 'and', 'children' => [] }
      exclude_tree = { 'type' => 'and', 'children' => [{ 'field' => 'status', 'operator' => 'equals', 'value' => 'qualified' }] }
      ids = described_class.new(
        company: company, source_type: 'Lead',
        filter_tree: include_tree, exclude_filter_tree: exclude_tree
      ).scope.pluck(:id)
      expect(ids).to contain_exactly(l_new.id)
    end
  end

  describe 'Contact source type' do
    it 'compiles against contacts and excludes deleted' do
      account = Account.create!(company: company, name: 'A1')
      c1 = Contact.create!(company: company, account: account, first_name: 'X', last_name: 'Y', email: 'x@e.com')
      c2 = Contact.create!(company: company, account: account, first_name: 'D', last_name: 'D', email: 'd@e.com', is_deleted: true)
      tree = { 'type' => 'and', 'children' => [] }
      ids = described_class.new(company: company, source_type: 'Contact', filter_tree: tree).scope.pluck(:id)
      expect(ids).to include(c1.id)
      expect(ids).not_to include(c2.id)
    end
  end

  describe 'Account source type' do
    it 'compiles against accounts' do
      a1 = Account.create!(company: company, name: 'Acme', account_type: 'customer')
      _a2 = Account.create!(company: other_company, name: 'Other')
      tree = { 'type' => 'and', 'children' => [{ 'field' => 'account_type', 'operator' => 'equals', 'value' => 'customer' }] }
      ids = described_class.new(company: company, source_type: 'Account', filter_tree: tree).scope.pluck(:id)
      expect(ids).to contain_exactly(a1.id)
    end
  end

  describe '#count and #sample' do
    it 'returns SQL count' do
      3.times { make_lead(company) }
      compiler = described_class.new(company: company, source_type: 'Lead', filter_tree: {})
      expect(compiler.count).to eq(3)
    end

    it 'sample returns up to N rows with id+name+email' do
      make_lead(company, first_name: 'Alice', last_name: 'Adams', email: 'a@e.com')
      compiler = described_class.new(company: company, source_type: 'Lead', filter_tree: {})
      sample = compiler.sample(limit: 1)
      expect(sample.size).to eq(1)
      expect(sample.first[:name]).to eq('Alice Adams')
      expect(sample.first[:email]).to eq('a@e.com')
    end
  end
end
