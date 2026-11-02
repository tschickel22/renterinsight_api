# frozen_string_literal: true

require 'rails_helper'

# Custom fields live in custom_field_values, written by forms and spreadsheet
# imports, so the stored shapes vary. Category was missing from the audience
# builder entirely because only built-in columns were offered.
RSpec.describe 'Audience custom field filters' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(3)}") }

  def define(field_key, field_type, target: company, module_name: 'leads', **attrs)
    CustomField.create!(company: target, module: module_name, name: field_key.humanize, field_key: field_key,
                        field_type: field_type, **attrs)
  end

  def lead(values)
    Lead.create!(company: company, first_name: 'A', last_name: 'B', email: "#{SecureRandom.hex(4)}@example.com",
                 custom_field_values: values)
  end

  def matches(key, operator, value = nil, source_type: 'Lead')
    leaf = { 'field' => "custom:#{key}", 'operator' => operator, 'value' => value }
    Audiences::FilterCompiler.new(company: company, source_type: source_type,
                                  filter_tree: { 'type' => 'and', 'children' => [leaf] }).scope.to_a
  end

  describe Audiences::FieldSchema do
    def field(key, source_type: 'Lead')
      described_class.for_source_type(source_type, company: company).find { |f| f[:key] == "custom:#{key}" }
    end

    it 'offers a text field as a list of the values records hold' do
      define('category', 'text', label: 'Category')
      lead('category' => 'Dealer')
      lead('category' => 'dealer ')
      lead('category' => 'Community')
      lead('category' => '')

      expect(field('category')).to include(label: 'Category', group: 'Custom fields', type: 'select',
                                           options: %w[Community Dealer])
    end

    it 'falls back to typing when a text field has too many different values' do
      define('website', 'text')
      (described_class::PICK_LIST_LIMIT + 1).times { |i| lead('website' => "site#{i}.com") }

      expect(field('website')).to include(type: 'string')
      expect(field('website')).not_to have_key(:options)
    end

    it 'keeps a pick list option nobody has chosen yet, and adds what an import stored' do
      define('competition', 'select', options: %w[Trove Monday])
      lead('competition' => 'In House')

      expect(field('competition')[:options]).to eq(['In House', 'Monday', 'Trove'])
    end

    it "shows only this company's active fields for that record type" do
      define('mine', 'text')
      define('off', 'text', is_active: false)
      define('contact_only', 'text', module_name: 'contacts')
      define('theirs', 'text', target: other_company)

      expect(field('mine')).to be_present
      expect(field('off')).to be_nil
      expect(field('contact_only')).to be_nil
      expect(field('theirs')).to be_nil
      expect(field('contact_only', source_type: 'Contact')).to be_present
    end

    it 'skips types with nothing to compare on' do
      define('rep', 'user')
      expect(field('rep')).to be_nil
    end

    it 'leaves a custom key that matches a built-in one separate' do
      define('title', 'text')
      keys = described_class.for_source_type('Lead', company: company).map { |f| f[:key] }
      expect(keys).to include('title', 'custom:title')
    end

    it 'keeps the static list without a company' do
      define('category', 'text')
      expect(described_class.for_source_type('Lead')).to eq(described_class::LEAD_FIELDS)
    end
  end

  describe Audiences::FilterCompiler do
    it 'matches text ignoring case and spaces; NOT includes records with no value' do
      define('category', 'text')
      dealer = lead('category' => ' Dealer')
      community = lead('category' => 'Community')
      none = lead({})

      expect(matches('category', 'equals', 'dealer')).to contain_exactly(dealer)
      expect(matches('category', 'in', %w[Dealer Community])).to contain_exactly(dealer, community)
      expect(matches('category', 'not_equals', 'Dealer')).to contain_exactly(community, none)
      expect(matches('category', 'contains', 'mmun')).to contain_exactly(community)
      expect(matches('category', 'not_contains', 'mmun')).to contain_exactly(dealer, none)
      expect(matches('category', 'is_set')).to contain_exactly(dealer, community)
      expect(matches('category', 'is_blank')).to contain_exactly(none)
    end

    it 'treats a percent or underscore in contains as literal' do
      define('category', 'text')
      hit = lead('category' => '100% Dealer')
      lead('category' => '100 Dealer')

      expect(matches('category', 'contains', '100%')).to contain_exactly(hit)
    end

    it 'compares numbers stored as numbers or strings, and ignores junk without raising' do
      define('units', 'number')
      number = lead('units' => 8.0)
      string = lead('units' => '12')
      lead('units' => 'lots')
      lead('units' => nil)

      expect(matches('units', 'greater_than', 5)).to contain_exactly(number, string)
      expect(matches('units', 'equals', 8)).to contain_exactly(number)
      expect(matches('units', 'less_than', 10)).to contain_exactly(number)
    end

    it 'compares ISO dates and ignores anything else without raising' do
      define('next_appointment', 'date')
      old = lead('next_appointment' => 30.days.ago.to_date.iso8601)
      recent = lead('next_appointment' => 1.day.ago.to_date.iso8601)
      lead('next_appointment' => 'soon')
      lead('next_appointment' => '2026-02-31x')
      lead('next_appointment' => '')

      expect(matches('next_appointment', 'days_since_greater_than', 10)).to contain_exactly(old)
      expect(matches('next_appointment', 'greater_than', 10.days.ago.to_date.iso8601)).to include(recent)
      expect(matches('next_appointment', 'greater_than', 10.days.ago.to_date.iso8601)).not_to include(old)
    end

    it 'reads a checkbox, with no value meaning No' do
      define('visited_booth', 'checkbox')
      yes = lead('visited_booth' => true)
      no = lead('visited_booth' => false)
      none = lead({})

      expect(matches('visited_booth', 'equals', true)).to contain_exactly(yes)
      expect(matches('visited_booth', 'equals', false)).to contain_exactly(no, none)
    end

    it 'matches a multiselect by any picked option, and an empty one counts as blank' do
      define('products', 'multiselect', options: %w[CRM Websites Accounting])
      both = lead('products' => %w[CRM Websites])
      single = lead('products' => 'CRM')
      empty = lead('products' => [])
      none = lead({})

      expect(matches('products', 'in', %w[Websites Accounting])).to contain_exactly(both)
      expect(matches('products', 'in', %w[CRM])).to contain_exactly(both, single)
      expect(matches('products', 'not_in', %w[CRM])).to contain_exactly(empty, none)
      expect(matches('products', 'is_blank')).to contain_exactly(empty, none)
    end

    it 'rejects a field this company does not have, including another company\'s' do
      define('theirs', 'text', target: other_company)
      expect { matches('theirs', 'equals', 'x') }.to raise_error(described_class::CompilationError, /Unknown field/)
    end

    it 'keeps working on a field turned off after the audience was saved' do
      define('category', 'text', is_active: false)
      hit = lead('category' => 'Dealer')
      expect(matches('category', 'equals', 'Dealer')).to contain_exactly(hit)
    end

    it 'handles a key with a hyphen, and contacts and accounts' do
      define('client-phase_status', 'text')
      hit = lead('client-phase_status' => 'Active')
      expect(matches('client-phase_status', 'equals', 'Active')).to contain_exactly(hit)

      define('category', 'text', module_name: 'accounts')
      account = Account.create!(company: company, name: 'Acme', email: 'acme@example.com', custom_field_values: { 'category' => 'Dealer' })
      expect(matches('category', 'equals', 'Dealer', source_type: 'Account')).to contain_exactly(account)
    end

    it 'works inside an OR group' do
      define('category', 'text')
      hit = lead('category' => 'Dealer')
      lead('category' => 'Other')
      tree = { 'type' => 'or', 'children' => [{ 'field' => 'custom:category', 'operator' => 'equals', 'value' => 'Dealer' },
                                               { 'field' => 'first_name', 'operator' => 'equals', 'value' => 'nobody' }] }
      expect(described_class.new(company: company, source_type: 'Lead', filter_tree: tree).scope.to_a).to contain_exactly(hit)
    end
  end
end
