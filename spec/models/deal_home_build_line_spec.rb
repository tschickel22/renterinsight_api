# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DealHomeBuildLine do
  # Names as they appear in the Champion Topeka book.
  it 'reads the unit from the option name' do
    {
      'Wood Beam On Ceiling - Per LF' => 'lf', '28 to 32 Wide Stretch -3/12 per LF' => 'lf', 'Beam Per Foot' => 'lf',
      'Vertical Board & Batten per SF' => 'sf', "Shake siding (SF) max 10'" => 'sf',
      'Pier Saver (each)' => 'each', 'LED Mirror Each - Upgrade Product' => 'each', 'Dishwasher' => 'each'
    }.each { |name, unit| expect(described_class.unit_for(name)).to eq(unit), name }
  end
end
