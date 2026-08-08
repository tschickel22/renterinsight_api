# frozen_string_literal: true

module SiteProfiles
  # The opening paragraph of the review: what we found and what it costs them.
  #
  # A report that opens with a number and then lists eighteen checks makes the
  # reader do the synthesis, and the reader is a dealer principal skimming it
  # between appointments. This says the same thing in four sentences, worst
  # finding first, in the language of consequences rather than of tags.
  #
  # Assembled from the findings rather than written by a model. The paragraph
  # travels to prospects with our name on it, so every clause has to be
  # derivable from what we actually measured. There is no sentence here that
  # says more than the checks support.
  module SeoReportSummary
    # What each finding costs a dealer, in their terms. Deliberately phrased as
    # an effect, never as an instruction: a client-facing sentence that reads
    # "add meta descriptions" is a work order their current agency can action
    # for free, which is the whole reason the client view withholds the how.
    CONSEQUENCES = {
      'local_business' => 'nothing tells Google this is a dealership at a physical address with hours, ' \
                          'which is what map and local results are built from',
      'structured_data' => 'individual homes are not described in a form search engines can read, so price ' \
                           'and availability never reach a search result',
      'crawlability' => 'the site turns away automated readers, so parts of it cannot be assessed at all',
      'descriptions' => 'pages carry no description, so search engines write the text under the link themselves',
      'titles' => 'page titles are missing or the wrong length, so the clickable headline in results gets ' \
                  'chosen for them',
      'mobile_viewport' => 'pages do not declare a mobile viewport, and the phone version is the one Google judges',
      'sitemap' => 'there is no usable sitemap, so new listings wait to be found',
      'canonical' => 'pages do not name their own address, so near duplicate pages compete with each other',
      'headings' => 'pages carry no clear heading, so nothing states what they are about',
      'thin_content' => 'pages carry too little text for a search engine to decide what they are for',
      'social_preview' => 'a link shared in a text or posted to Facebook arrives as bare text with no picture',
      'mixed_content' => 'some assets load insecurely, which browsers warn visitors about',
      'image_alt' => 'photographs carry no alt text, so they are invisible to image search and to screen readers',
      'render_blocking' => 'scripts run before the page can paint, delaying what a visitor sees',
      'page_weight' => 'pages are unusually heavy, which is felt first on a phone',
      'breadcrumbs' => 'results do not show where a page sits in the site',
      'language' => 'pages do not declare what language they are written in',
      'robots' => 'crawling is left to chance rather than directed'
    }.freeze

    # The single line that turns the findings into a business consequence, keyed
    # by whichever finding carries the most weight.
    MEANING = {
      'local_business' => 'In practice, a buyer searching for homes in this area may not find this ' \
                          'dealership at all.',
      'structured_data' => 'In practice, the homes on this lot do not reach buyers with a price attached, ' \
                           'which is how people shop.',
      'crawlability' => 'In practice, some of what buyers would search for cannot be read by anything ' \
                        'other than a person already on the site.',
      'descriptions' => 'In practice, the site appears in results described in words nobody at the ' \
                        'dealership chose.',
      'titles' => 'In practice, the site appears in results under headlines nobody at the dealership chose.'
    }.freeze

    DEFAULT_MEANING = 'In practice, the site competes for buyers without the groundwork search engines ' \
                      'and AI assistants rely on to understand it.'

    # More than three and it stops being a paragraph a busy reader finishes.
    MAX_FINDINGS = 3

    module_function

    # @param report [Hash] a report from SeoAudit, either view
    # @return [String, nil] the paragraph, or nil when there is nothing to say
    def call(report)
      data = report.presence&.deep_stringify_keys
      return nil if data.blank?

      score = data['score']
      return nil if score.nil?

      gaps = Array(data['checks']).reject { |c| c['status'] == 'pass' }
      return clean_bill(data, score) if gaps.empty?

      [opening(data, score), findings_sentences(gaps), meaning(gaps)].compact_blank.join(' ')
    end

    def opening(data, score)
      pages = data['pages_checked'].to_i
      domain = data['domain'].presence || 'This site'
      counted = pages.positive? ? " across #{pages} #{pages == 1 ? 'page' : 'pages'} reviewed" : ''

      "#{domain} scores #{score} out of 100#{counted}."
    end

    def clean_bill(data, score)
      "#{opening(data, score)} Nothing came back that would hold the site out of search results, " \
        'which is rare and worth saying plainly.'
    end

    COUNT_WORDS = { 1 => 'One thing stands out', 2 => 'Two things stand out',
                    3 => 'Three things stand out' }.freeze

    # Heaviest first, because the top of the paragraph is the part that gets
    # read, and weight is our own statement of what matters most.
    #
    # One sentence per finding rather than a list. Each clause already carries
    # its own comma explaining the consequence, so joining them with commas and
    # an "and" produced a sentence nobody finished.
    def findings_sentences(gaps)
      ranked = gaps.sort_by { |c| [c['status'] == 'fail' ? 0 : 1, -c['weight'].to_i] }
      clauses = ranked.first(MAX_FINDINGS).filter_map { |c| CONSEQUENCES[c['key'].to_s] }
      return nil if clauses.empty?

      lead = COUNT_WORDS.fetch(clauses.size, 'The findings that matter most')
      "#{lead}. #{clauses.map { |clause| "#{clause[0].upcase}#{clause[1..]}." }.join(' ')}"
    end

    def meaning(gaps)
      top = gaps.min_by { |c| [c['status'] == 'fail' ? 0 : 1, -c['weight'].to_i] }
      MEANING.fetch(top['key'].to_s, DEFAULT_MEANING)
    end
  end
end
