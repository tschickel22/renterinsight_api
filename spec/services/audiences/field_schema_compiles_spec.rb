# frozen_string_literal: true

require 'rails_helper'

# Every field the filter builder offers must be one the compiler accepts. Lead
# "Score" and "Source" were offered for months while the compiler rejected
# both with "Unknown field".
RSpec.describe Audiences::FieldSchema do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  %w[Lead Contact Account].each do |source_type|
    described_class.for_source_type(source_type).each do |field|
      next if field[:type] == 'tags'

      it "compiles #{source_type} #{field[:key]}" do
        value = field[:type] == 'number' ? 1 : (field[:type] == 'boolean' ? true : 'x')
        leaf = { 'field' => field[:key], 'operator' => field[:operators].first, 'value' => value }
        compiler = Audiences::FilterCompiler.new(company: company, source_type: source_type,
                                                 filter_tree: { 'type' => 'and', 'children' => [leaf] })
        expect { compiler.scope.to_a }.not_to raise_error
      end
    end
  end
end
