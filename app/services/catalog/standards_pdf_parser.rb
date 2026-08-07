# frozen_string_literal: true

require 'pdf-reader'
require 'stringio'

module Catalog
  # Parses an Adventure Homes "Standard Features" sheet into sections of feature
  # bullets, ready for NormalizedHome#features.
  #
  # WHY POSITIONAL, NOT page.text. These sheets are laid out in two print
  # columns. PDF::Reader's plain #text walks the content stream in draw order,
  # which interleaves the columns and glues unrelated bullets onto one line
  # ("Thermal Zone III Construction   Electrical, Plumbing & Heating"). Reading
  # the positioned runs and splitting on x recovers the columns intact.
  #
  # ORDER MATTERS: split into columns BEFORE grouping runs into lines. The two
  # columns' section headings often share a baseline ("Exterior" opposite
  # "Electrical, Plumbing & Heating"), so grouping first fuses them into one
  # nonsense heading.
  #
  # THREE SIGNALS, ALL CALIBRATED AGAINST THE LIVE SHEETS (Lakeside, Mojave,
  # Kalahari, Sahara Modular, all dated 19 Jan 2026):
  #   * font size — bullets are the modal size (10pt), section headings are
  #     larger (14/16pt), the series title is largest (36pt) and the footer /
  #     disclaimer smaller (6-8pt). So headings are "bigger than a bullet but
  #     not title-sized", which survives a sheet that renames its sections.
  #   * x position — column membership, and within a column an indented run is a
  #     wrapped continuation of the bullet above it ("& All Bedrooms"), not a
  #     new bullet.
  #   * y position — line grouping, reading order, and the footer cutoff.
  #
  # These are SERIES-level features, not per-home facts, and the sheet says so
  # itself. The caller is responsible for labelling them that way.
  class StandardsPdfParser
    # A heading is larger than a bullet but no more than this multiple of it.
    # Bullets are 10pt and headings 14-16pt, while "Standard Features" (18pt)
    # and the series title (36pt) are page furniture, not sections.
    HEADING_MAX_RATIO = 1.7

    # Runs whose left edge sits more than this many points right of the column's
    # bullet margin are wrapped continuations of the previous bullet.
    INDENT_TOLERANCE = 8.0

    # Same-baseline tolerance when grouping runs into visual lines.
    LINE_TOLERANCE = 2.0

    # Letter width; only used if the PDF omits a usable MediaBox.
    DEFAULT_PAGE_WIDTH = 612.0

    # Small print shorter than this is a stray glyph (the "th" of "January 19th"
    # is its own run), not the manufacturer's disclaimer.
    MIN_DISCLAIMER_CHARS = 20

    # Horizontal gap between two runs, as a fraction of the font size, that
    # means a real word break rather than kerning.
    SPACE_GAP_RATIO = 0.15

    # Vertical reach of the disclaimer block, measured from its lowest line.
    # Keeps a two or three line disclaimer together without swallowing the
    # mid-page small print far above it.
    DISCLAIMER_CLUSTER_GAP = 30.0

    Result = Struct.new(:title, :sections, :disclaimer, keyword_init: true) do
      def any?
        sections.present? && sections.values.any?(&:present?)
      end

      # Total bullets across every section — the health signal a caller logs.
      def feature_count
        sections.values.sum { |items| Array(items).size }
      end
    end

    EMPTY = Result.new(title: nil, sections: {}, disclaimer: nil).freeze

    # @param bytes [String] raw PDF bytes
    # @return [Result] never raises; an unreadable PDF yields an empty Result
    def self.parse(bytes)
      new(bytes).call
    end

    def initialize(bytes)
      @bytes = bytes.to_s
    end

    def call
      return EMPTY if @bytes.blank?

      sections = {}
      title = nil
      disclaimer = nil

      PDF::Reader.new(StringIO.new(@bytes)).pages.each do |page|
        runs = runs_for(page)
        next if runs.empty?

        body = body_size(runs)
        next if body.nil?

        title ||= extract_title(runs)
        page_disclaimer = extract_disclaimer(runs, body)
        disclaimer ||= page_disclaimer

        merge_sections!(sections, page, runs, body)
      end

      Result.new(title: title, sections: anchored_sections(sections), disclaimer: disclaimer)
    rescue StandardError => e
      Rails.logger.warn "[#{self.class.name}] parse failed: #{e.class}: #{e.message}"
      EMPTY
    end

    private

    def runs_for(page)
      receiver = PDF::Reader::PageTextReceiver.new
      page.walk(receiver)
      receiver.runs.reject { |r| r.text.to_s.strip.empty? }
    end

    # Bullets are the most common size on a full sheet. Ties break toward the
    # SMALLER size, because a sparse sheet can leave every size tied and the
    # bullets are always the smallest of the body sizes — picking the title
    # instead would classify the real content as page furniture.
    def body_size(runs)
      runs.map { |r| r.font_size.round(1) }
          .tally
          .max_by { |size, count| [count, -size] }&.first
    end

    # Group one column's runs into visual lines: x (left edge), y (baseline),
    # size, text.
    def lines_for(runs)
      runs.group_by { |r| (r.y / LINE_TOLERANCE).round }
          .map { |_, group| build_line(group) }
          .reject { |line| line[:text].empty? }
    end

    def build_line(group)
      ordered = group.sort_by(&:x)
      {
        x:    ordered.first.x,
        y:    ordered.first.y,
        size: ordered.map(&:font_size).max.round(1),
        text: clean(join_runs(ordered))
      }
    end

    # A kerned line arrives as several runs, and a blind join(' ') splits words
    # ("Lakeside Serie s"). Insert a space only where the next run actually
    # starts clear of where the previous one ended.
    def join_runs(ordered)
      ordered.each_with_index.map do |run, index|
        text = run.text.to_s
        next text if index.zero?

        previous = ordered[index - 1]
        gap = run.x - (previous.x + previous.width.to_f)
        gap > previous.font_size * SPACE_GAP_RATIO ? " #{text}" : text
      end.join
    end

    # Kerned PDFs emit stray spaces mid-token: "(1 ) E xterior Faucet". Repair
    # the shapes we actually see rather than guessing at word boundaries.
    def clean(text)
      text.gsub(/\s+/, ' ')
          .gsub(/\(\s+/, '(')
          .gsub(/\s+\)/, ')')
          .gsub(/\b([A-Z]) (?=[a-z])/, '\1')
          .strip
    end

    def heading?(line, body)
      line[:size] > body && line[:size] <= body * HEADING_MAX_RATIO
    end

    def bullet?(line, body)
      line[:size] == body
    end

    # The series name is the largest text on the page ("Lakeside Series").
    def extract_title(runs)
      biggest = runs.max_by(&:font_size)
      return nil if biggest.nil?

      # Only the runs sharing that baseline AND that size, so the 18pt
      # "Standard Features" alongside it stays out of the name.
      same = runs.select do |r|
        r.font_size == biggest.font_size && (r.y - biggest.y).abs <= LINE_TOLERANCE
      end
      clean(join_runs(same.sort_by(&:x))).presence
    end

    # Boilerplate set in the smallest type below every bullet, e.g. "Because of
    # continuous product improvements, specifications are subject to change
    # without notice or obligation." Anchored below the last bullet so a
    # mid-page footnote in the same small type is not mistaken for it.
    def extract_disclaimer(runs, body)
      lines = disclaimer_lines(runs, body)
      return nil if lines.empty?

      lines.map { |l| l[:text] }.join(' ').presence
    end

    # The bottom-most cluster of small-type lines. Anchoring on "below the last
    # bullet" does not work: the letterhead address under the disclaimer is set
    # at bullet size, so the lowest bullet is beneath the disclaimer, not above
    # it. These sheets also carry mid-page small print (the insulation caveat
    # under the R-value bullet), which the cluster rule correctly leaves behind.
    def disclaimer_lines(runs, body)
      candidates = lines_for(runs.select { |r| r.font_size.round(1) < body })
                   .select { |l| l[:text].length >= MIN_DISCLAIMER_CHARS }
      return [] if candidates.empty?

      bottom = candidates.map { |l| l[:y] }.min
      candidates.select { |l| l[:y] <= bottom + DISCLAIMER_CLUSTER_GAP }
                .sort_by { |l| -l[:y] }
    end

    # Walk each column top-to-bottom. A heading opens a section, bullets fill
    # it, indented lines extend the bullet above them.
    #
    # The letterhead footer (brand name over address, phone, website) sets its
    # brand line larger than a bullet, so it reads as a section heading with the
    # address as its features. It is rejected structurally rather than by a
    # y cutoff: the footer is centered, so none of its lines sit at a column's
    # bullet margin. A y cutoff looked simpler but clipped real bullets from
    # whichever column ran lower than the opposite column's disclaimer.
    def merge_sections!(sections, page, runs, body)
      columns(page, runs, body).each do |column_runs|
        column = lines_for(column_runs)
        margin = bullet_margin(column, body)
        current = nil

        column.sort_by { |l| -l[:y] }.each do |line|
          if heading?(line, body)
            current = line[:text]
            sections[current] ||= []
          elsif bullet?(line, body)
            next if current.nil? # page furniture above the first heading

            if margin && line[:x] > margin + INDENT_TOLERANCE
              # Indented: a wrapped continuation when there is a bullet to
              # extend, otherwise page furniture masquerading as a section.
              sections[current][-1] = "#{sections[current].last} #{line[:text]}".squeeze(' ') if sections[current].any?
            else
              sections[current] << line[:text]
              @anchored ||= Set.new
              @anchored << current
            end
          end
        end
      end

      sections.each_value(&:uniq!)
    end

    # Sections that never took a bullet at their column's margin are page
    # furniture, not content.
    def anchored_sections(sections)
      keep = @anchored || Set.new
      sections.select { |name, items| items.any? && keep.include?(name) }
    end

    # Split into left/right print columns at the page midpoint. A single-column
    # sheet simply yields one group.
    def columns(page, runs, body)
      midpoint = page_width(page) / 2.0
      # Anchor the split on bullets: headings and footers sit at their own
      # indents and would skew a midpoint derived from every run.
      bullets = runs.select { |r| r.font_size.round(1) == body }
      return [runs] if bullets.empty? || bullets.all? { |r| r.x < midpoint } ||
                       bullets.all? { |r| r.x >= midpoint }

      left, right = runs.partition { |r| r.x < midpoint }
      [left, right].reject(&:empty?)
    end

    # The x every bullet in this column starts at. Wrapped continuations are the
    # lines that sit right of it.
    def bullet_margin(column, body)
      xs = column.select { |l| bullet?(l, body) }.map { |l| l[:x].round }
      return nil if xs.empty?

      xs.tally.max_by { |_, count| count }.first.to_f
    end

    def page_width(page)
      box = page.attributes[:MediaBox]
      width = box && (box[2].to_f - box[0].to_f)
      width&.positive? ? width : DEFAULT_PAGE_WIDTH
    rescue StandardError
      DEFAULT_PAGE_WIDTH
    end
  end
end
