# frozen_string_literal: true

module SiteProfiles
  # Checks for how well a site is built to be read, understood and quoted by AI
  # assistants and answer engines (ChatGPT, Perplexity, Claude, Google AI
  # Overviews): "GEO" and "AEO" in the trade.
  #
  # Same rule as the rest of SeoAudit: every finding is specific and checkable.
  # None of this promises a citation. It measures whether the preconditions for
  # one are in place, which is the part a site owner controls.
  module AiSearchChecks
    # The crawlers that fetch pages for AI answers and training, by the name
    # each operator documents. A block on any of these is a site opting out.
    AI_BOTS = %w[GPTBot OAI-SearchBot ChatGPT-User ClaudeBot Claude-SearchBot PerplexityBot Google-Extended CCBot].freeze

    # Below this, outside the app's mount point, a page sent no text of its
    # own. Kept low on purpose: a short page with a heading and an address is
    # thin, which thin_content reports, not invisible.
    JS_ONLY_WORDS = 15
    APP_MOUNTS = '#root, #app, #__next, #__nuxt, [data-reactroot], app-root'

    # Placeholder contact details that shipped in a template and were never
    # replaced. An assistant quoting these gives buyers a number that rings
    # nowhere, and the mismatch with the real one costs local trust.
    PLACEHOLDER_PHONE = /\(?\b555\)?[\s.-]?\d{3}[\s.-]?\d{4}\b|\b\d{3}[\s.-]555[\s.-]0\d{3}\b/
    PLACEHOLDER_TEXT = /your (dealership|business|company) name|123 main st|yourdealership\.com|lorem ipsum/i

    FRESH_DAYS = 90
    QUESTION_START = /\A(how|what|why|when|where|who|which|can|do|does|is|are|should|will)\b/i

    def ai_search_checks
      checks = [
        ai_crawler_check,
        ai_readable_check,
        faq_check,
        question_heading_check,
        nap_consistency_check,
        freshness_check,
        llms_txt_check
      ].compact
      checks.each { |c| c.category = 'ai' }
    end

    private

    # --- crawler access -------------------------------------------------------

    def ai_crawler_check
      response = site_file('/robots.txt')
      return nil if response.nil? && @from_archive

      blocked = AI_BOTS.select { |bot| robots_blocks?(response&.body.to_s, bot) }
      if blocked.empty?
        return pass_check('ai_crawlers', 'AI assistant access', 9, 'AI assistants are allowed to read the site')
      end

      fail_check('ai_crawlers', 'AI assistant access', 9,
                 "robots.txt blocks #{blocked.size} AI #{blocked.size == 1 ? 'crawler' : 'crawlers'}",
                 "Blocked: #{blocked.join(', ')}. ChatGPT, Claude and Perplexity cannot read or quote a " \
                 'site their crawler is told to stay out of, so the business is left out of those answers.')
    end

    # Groups that name the bot win over "*", which is how crawlers read the file.
    def robots_blocks?(body, bot)
      groups = parse_robots(body)
      rules = groups.detect { |agents, _| agents.any? { |a| a.casecmp?(bot) } }&.last ||
              groups.detect { |agents, _| agents.include?('*') }&.last
      return false if rules.nil?

      disallow_all = rules.any? { |kind, path| kind == 'disallow' && path == '/' }
      allow_all = rules.any? { |kind, path| kind == 'allow' && path == '/' }
      disallow_all && !allow_all
    end

    def parse_robots(body)
      groups = []
      agents = []
      rules = nil
      body.to_s.each_line do |raw|
        line = raw.sub(/#.*/, '').strip
        next if line.empty?

        field, value = line.split(':', 2).map { |x| x.to_s.strip }
        case field.downcase
        when 'user-agent'
          if rules
            groups << [agents, rules]
            agents = []
            rules = nil
          end
          agents << value
        when 'allow', 'disallow'
          rules ||= []
          rules << [field.downcase, value]
        end
      end
      groups << [agents, rules || []] if agents.any?
      groups
    end

    # --- readable without JavaScript -----------------------------------------

    # Most AI crawlers download the HTML and read it; they do not run the
    # JavaScript that builds a single-page app. Google does, which is how such a
    # site can rank and still be invisible to every assistant.
    def ai_readable_check
      empty = docs.select do |_, doc|
        mount = doc.at_css(APP_MOUNTS)
        mount && mount.text.squish.empty? && body_words(doc.dup) < JS_ONLY_WORDS
      end.keys
      needed_browser = @js_only_pages.to_i

      if empty.empty? && needed_browser.zero?
        return pass_check('ai_readable', 'Readable without JavaScript', 9,
                          'Page text is in the HTML, where AI crawlers can read it')
      end

      count = [empty.size, needed_browser].max
      fail_check('ai_readable', 'Readable without JavaScript', 9,
                 "#{count} #{pluralize_pages(count)} show their text only after JavaScript runs",
                 'The HTML these pages send is an empty app shell; the words appear once a browser ' \
                 'runs the scripts. Google does that. ChatGPT, Claude and Perplexity largely do not, ' \
                 'so to them these pages are blank.', empty)
    end

    # --- answerable content ---------------------------------------------------

    # Questions with short answers are the passages assistants lift most often.
    def faq_check
      marked = schema_types.key?('FAQPage')
      faq_pages = docs.select { |_, doc| faq_like?(doc) }.keys

      if marked
        return pass_check('faq', 'FAQs for AI answers', 7, 'FAQ content is marked up as FAQPage')
      end

      if faq_pages.any?
        return warn_check('faq', 'FAQs for AI answers', 7,
                          "#{faq_pages.size} #{pluralize_pages(faq_pages.size)} have FAQs with no FAQ markup",
                          'The questions are on the page but not marked as questions and answers, so an ' \
                          'engine has to guess where each answer starts and ends.', faq_pages)
      end

      warn_check('faq', 'FAQs for AI answers', 7, 'No FAQ content',
                 'Buyers ask assistants questions ("do they finance?", "what does delivery cost?"). A ' \
                 'site that answers them in its own words is the one that gets quoted.')
    end

    def faq_like?(doc)
      return true if doc.css('h1, h2, h3').any? { |h| h.text.match?(/\b(faqs?|frequently asked)\b/i) }

      doc.css('h2, h3, h4, summary, dt').count { |h| h.text.strip.end_with?('?') } >= 3
    end

    def question_heading_check
      headings = docs.values.flat_map { |doc| doc.css('h2, h3').map { |h| h.text.squish } }.reject(&:blank?)
      questions = headings.count { |h| h.end_with?('?') || h.match?(QUESTION_START) }
      return nil if headings.size < 4

      if questions >= 3
        pass_check('question_headings', 'Headings that answer questions', 3,
                   "#{questions} headings are phrased as questions")
      else
        warn_check('question_headings', 'Headings that answer questions', 3,
                   'Few headings are phrased the way people ask',
                   'Answer engines match a question to the section whose heading asks it. "Financing" ' \
                   'is weaker than "Can I finance a manufactured home?" followed by a direct answer.')
      end
    end

    # --- trust signals ---------------------------------------------------------

    def nap_consistency_check
      placeholders = docs.select { |_, doc| visible_text(doc).match?(PLACEHOLDER_PHONE) || visible_text(doc).match?(PLACEHOLDER_TEXT) }.keys
      if placeholders.any?
        return fail_check('nap', 'Business details', 7,
                          "Placeholder contact details on #{placeholders.size} #{pluralize_pages(placeholders.size)}",
                          'Template text like a 555 phone number or "Your Dealership Name" is still on the ' \
                          'site. An assistant can quote it as fact.', placeholders)
      end

      schema_phones = schema_nodes.values.flatten.filter_map { |n| digits(n['telephone']) if n['telephone'].present? }.uniq
      return nil if schema_phones.empty?

      page_phones = docs.values.flat_map { |doc| visible_text(doc).scan(/\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/).map { |p| digits(p) } }.uniq
      if page_phones.empty? || (page_phones & schema_phones).any?
        pass_check('nap', 'Business details', 7, 'Name, address and phone agree with the markup')
      else
        warn_check('nap', 'Business details', 7, 'The phone number on the page differs from the markup',
                   "Markup says #{schema_phones.join(', ')}; pages show #{page_phones.first(3).join(', ')}. " \
                   'Engines trust a business whose details agree everywhere.')
      end
    end

    def freshness_check
      dates = docs.values.flat_map do |doc|
        doc.css('time[datetime]').map { |t| t['datetime'] } +
          doc.css('meta[property="article:modified_time"], meta[property="article:published_time"]').map { |m| m['content'] }
      end
      dates += schema_nodes.values.flatten.flat_map { |n| [n['dateModified'], n['datePublished']] }
      newest = dates.compact.filter_map { |d| Time.zone.parse(d.to_s) rescue nil }.max

      if newest.nil?
        return warn_check('freshness', 'Dated, recent content', 4, 'No dated content found',
                          'Assistants prefer sources that show when they were written. Posts and pages ' \
                          'with visible dates, updated regularly, read as current.')
      end

      age = ((Time.current - newest) / 1.day).floor
      if age <= FRESH_DAYS
        pass_check('freshness', 'Dated, recent content', 4, "Newest dated content is #{age} days old")
      else
        warn_check('freshness', 'Dated, recent content', 4, "Newest dated content is #{age} days old",
                   'Nothing on the site has been published or updated in three months.')
      end
    end

    # A new convention (llmstxt.org), so it is weighted lightly and said so.
    def llms_txt_check
      response = site_file('/llms.txt')
      return nil if response.nil? && @from_archive

      if response&.body.to_s.lstrip.start_with?('#')
        pass_check('llms_txt', 'llms.txt summary', 2, 'Publishes an llms.txt summary for AI assistants')
      else
        warn_check('llms_txt', 'llms.txt summary', 2, 'No llms.txt',
                   'An emerging convention: a plain-text summary of who the business is and which pages ' \
                   'matter, written for AI assistants. Not yet required by any engine.')
      end
    end

    def visible_text(doc)
      @visible_text ||= {}
      @visible_text[doc.object_id] ||= begin
        body = doc.at_css('body')&.dup
        body&.css('script, style, noscript')&.each(&:remove)
        body&.text.to_s.squish
      end
    end

    def digits(value)
      value.to_s.gsub(/\D/, '').last(10)
    end
  end
end
