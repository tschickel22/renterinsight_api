# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Audiences::FilterCompiler, 'address fields' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  def lead(attrs)
    Lead.create!({ company: company, source: source, first_name: 'A', last_name: 'B',
                   email: "l-#{SecureRandom.hex(3)}@x.com" }.merge(attrs))
  end

  let!(:denver)  { lead(city: 'Denver', state: 'CO', zip: '80202') }
  let!(:boulder) { lead(city: 'boulder ', state: 'co ', zip: '80301') }
  let!(:austin)  { lead(city: 'Austin', state: 'TX', zip: '73301') }
  let!(:unknown) { lead(city: nil, state: nil, zip: nil) }

  def ids(leaf)
    described_class.new(company: company, source_type: 'Lead',
                        filter_tree: { 'type' => 'and', 'children' => [leaf] }).scope.pluck(:id)
  end

  it 'matches a state whatever its case or spacing' do
    expect(ids('field' => 'state', 'operator' => 'equals', 'value' => 'co')).to contain_exactly(denver.id, boulder.id)
  end

  it 'matches any of several states' do
    expect(ids('field' => 'state', 'operator' => 'in', 'value' => %w[CO TX])).to contain_exactly(denver.id, boulder.id, austin.id)
  end

  it 'excludes a state, keeping leads with no state' do
    expect(ids('field' => 'state', 'operator' => 'not_equals', 'value' => 'CO')).to contain_exactly(austin.id, unknown.id)
  end

  it 'matches a city ignoring case and spaces' do
    expect(ids('field' => 'city', 'operator' => 'equals', 'value' => 'Boulder')).to contain_exactly(boulder.id)
  end

  it 'reaches an area by zip prefix' do
    expect(ids('field' => 'zip', 'operator' => 'starts_with', 'value' => '80')).to contain_exactly(denver.id, boulder.id)
  end

  it 'offers the address fields to the filter builder' do
    keys = Audiences::FieldSchema.for_source_type('Lead').map { |f| f[:key] }
    expect(keys).to include('city', 'state', 'zip')
  end
end
