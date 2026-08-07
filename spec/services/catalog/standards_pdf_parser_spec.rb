# frozen_string_literal: true

require 'rails_helper'

# Fixtures are generated with Prawn rather than checked in as binaries, so the
# layout traits under test are explicit: two print columns, section headings set
# larger than bullets, a series title larger still, wrapped bullets indented
# under their parent, and a small-print disclaimer above a centered letterhead.
# That is the real shape of an Adventure Homes Standard Features sheet.
RSpec.describe Catalog::StandardsPdfParser do
  BULLET_SIZE  = 10
  HEADING_SIZE = 14
  TITLE_SIZE   = 36
  SMALL_SIZE   = 8

  LEFT_MARGIN  = 72
  RIGHT_MARGIN = 320
  INDENT       = 40

  # @param columns [Hash] margin x => [[:heading|:bullet|:wrapped, text], ...]
  def build_pdf(columns:, title: 'Lakeside Series', disclaimer: nil, letterhead: true)
    pdf = Prawn::Document.new(page_size: 'LETTER', margin: 0)
    pdf.font 'Helvetica'

    # Same baseline, different sizes — as on the real sheet. Keep them clear of
    # each other horizontally: overlapping draws make PDF::Reader interleave the
    # two strings run by run, which is a fixture artefact, not a sheet we parse.
    pdf.draw_text title, at: [110, 722], size: TITLE_SIZE
    pdf.draw_text 'Standard Features', at: [400, 722], size: 18

    columns.each do |margin, entries|
      y = 690
      entries.each do |kind, text|
        case kind
        when :heading
          pdf.draw_text text, at: [margin + 6, y], size: HEADING_SIZE
        when :wrapped
          pdf.draw_text text, at: [margin + INDENT, y], size: BULLET_SIZE
        else
          pdf.draw_text text, at: [margin, y], size: BULLET_SIZE
        end
        y -= 16
      end
    end

    pdf.draw_text disclaimer, at: [89, 172], size: SMALL_SIZE if disclaimer
    if letterhead
      # Centered, larger than a bullet — the trap that reads as a section.
      pdf.draw_text 'Adventure Homes', at: [261, 76], size: 12
      pdf.draw_text '1119 Fuller Drive Garrett, IN 46738', at: [230, 62], size: BULLET_SIZE
      pdf.draw_text 'www.AdventureHomes.net', at: [245, 48], size: BULLET_SIZE
    end
    pdf.render
  end

  let(:two_column_pdf) do
    build_pdf(
      title: 'Lakeside Series',
      disclaimer: 'Because of continuous product improvements, specifications are subject to change.',
      columns: {
        LEFT_MARGIN => [
          [:heading, 'Exterior'],
          [:bullet,  'Thermal Zone III Construction'],
          [:bullet,  'LP Smartside Corners & Lineals'],
          [:wrapped, '(Match Exterior Siding Color)'],
          [:heading, 'Interior'],
          [:bullet,  'Vinyl Flooring Throughout']
        ],
        RIGHT_MARGIN => [
          [:heading, 'Electrical, Plumbing & Heating'],
          [:bullet,  'Smoke Detectors in Main Living Areas'],
          [:wrapped, '& All Bedrooms'],
          [:heading, 'Kitchen'],
          [:bullet,  'Black 18cf Refrigerator']
        ]
      }
    )
  end

  subject(:result) { described_class.parse(two_column_pdf) }

  describe 'column separation' do
    it 'keeps each column\'s sections intact' do
      expect(result.sections.keys)
        .to contain_exactly('Exterior', 'Interior', 'Electrical, Plumbing & Heating', 'Kitchen')
    end

    # The regression that motivated reading positioned runs: PDF::Reader#text
    # walks draw order and fuses the two columns' headings into one line.
    it 'does not fuse headings that share a baseline' do
      expect(result.sections.keys).not_to include(a_string_matching(/Exterior Electrical/))
    end

    it 'assigns bullets to the section above them in their own column' do
      expect(result.sections['Exterior']).to include('Thermal Zone III Construction')
      expect(result.sections['Kitchen']).to eq(['Black 18cf Refrigerator'])
    end
  end

  describe 'wrapped bullets' do
    it 'joins an indented line onto the bullet it continues' do
      expect(result.sections['Electrical, Plumbing & Heating'])
        .to eq(['Smoke Detectors in Main Living Areas & All Bedrooms'])
    end

    it 'does not emit the continuation as a bullet of its own' do
      expect(result.sections['Exterior']).not_to include('(Match Exterior Siding Color)')
      expect(result.sections['Exterior'])
        .to include('LP Smartside Corners & Lineals (Match Exterior Siding Color)')
    end
  end

  describe 'page furniture' do
    it 'takes the series name from the largest text, without the strapline' do
      expect(result.title).to eq('Lakeside Series')
    end

    it 'keeps the centered letterhead out of the sections' do
      expect(result.sections.keys).not_to include('Adventure Homes')
      expect(result.sections.values.flatten).not_to include(a_string_matching(/Fuller Drive/))
    end

    it 'captures the disclaimer' do
      expect(result.disclaimer).to match(/subject to change/)
    end

    it 'counts only real features' do
      expect(result.feature_count).to eq(5)
      expect(result).to be_any
    end
  end

  describe 'single column sheets' do
    let(:single) do
      build_pdf(letterhead: false, columns: {
                  LEFT_MARGIN => [[:heading, 'Frame & Floor'], [:bullet, '2x8 Floor Joists']]
                })
    end

    it 'parses without a column split' do
      parsed = described_class.parse(single)
      expect(parsed.sections).to eq('Frame & Floor' => ['2x8 Floor Joists'])
    end
  end

  describe 'bad input' do
    it 'returns an empty result for blank bytes' do
      expect(described_class.parse('')).to eq(described_class::EMPTY)
    end

    it 'returns an empty result rather than raising on a non-PDF' do
      expect(described_class.parse('this is not a pdf')).not_to be_any
    end

    it 'returns an empty result for a PDF with no text' do
      blank = Prawn::Document.new.render
      expect(described_class.parse(blank).sections).to be_empty
    end
  end
end
