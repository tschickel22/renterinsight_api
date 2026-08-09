# frozen_string_literal: true

require 'prawn'
require 'net/http'

module SiteProfiles
  # The SEO review as a document a rep can send or bring to a meeting.
  #
  # Ours, not the dealer's. The demo carries their branding because it is a
  # preview of their site; this is our assessment of it, so it wears ours and
  # says who wrote it. Branding comes from the brand kernel rather than
  # literals, so a rebrand or a per-tenant whitelabel is a settings change.
  #
  # Findings only, in severity order, with the offending URLs. What makes the
  # report useful in a meeting is that a dealer can hand the page to whoever
  # built their site; a score with no addresses cannot be acted on.
  class SeoReportPdf
    STATUS_LABEL = { 'fail' => 'MISSING', 'warn' => 'NEEDS WORK', 'pass' => 'GOOD' }.freeze
    STATUS_COLOR = { 'fail' => 'C0392B', 'warn' => 'B9770E', 'pass' => '1E8449' }.freeze
    MUTED = '666666'
    INK = '222222'

    # audience: :internal keeps the page addresses and the detail, because a rep
    # needs specifics to speak credibly and we have to fix them once we win.
    # audience: :client is the leave-behind: what is wrong and what it costs,
    # without the addresses, so it cannot be forwarded to the incumbent as a
    # work order.
    def initialize(profile, audience: :internal)
      @profile = profile
      @audience = audience.to_sym
      @report = (
        @audience == :client ? SeoReportView.client(profile.seo_report) : SeoReportView.internal(profile.seo_report)
      ).to_h
      @brand = Brand.current
    end

    def client?
      @audience == :client
    end

    def filename
      domain = @report['domain'].presence || 'site'
      suffix = client? ? '' : '-internal'
      "seo-review-#{domain.parameterize}#{suffix}-#{Time.current.strftime('%Y-%m-%d')}.pdf"
    end

    def render
      pdf = Prawn::Document.new(page_size: 'LETTER', margin: [45, 45, 55, 45])
      header(pdf)
      summary(pdf)
      findings(pdf)
      closing(pdf)
      footer(pdf)
      pdf.render
    end

    private

    def header(pdf)
      logo = load_image(@brand.logo_url)
      if logo
        # fit, not scale: a wordmark and a square icon are both plausible and
        # neither should be stretched.
        pdf.image(StringIO.new(logo), height: 28, position: :left) rescue nil
        pdf.move_down 10
      else
        pdf.fill_color INK
        pdf.text @brand.name.to_s, size: 16, style: :bold
        pdf.move_down 6
      end

      pdf.fill_color INK
      pdf.text 'Website Review', size: 22, style: :bold
      pdf.fill_color MUTED
      pdf.text @report['domain'].to_s, size: 12
      pdf.text "Prepared #{Time.current.strftime('%-d %B %Y')}", size: 9
      pdf.move_down 14
      pdf.stroke_color 'DDDDDD'
      pdf.stroke_horizontal_rule
      pdf.move_down 14
    end

    def summary(pdf)
      score = @report['score']
      gaps = @report['gap_count'].to_i
      pages = @report['pages_checked'].to_i

      pdf.fill_color INK
      pdf.text "Score #{score.nil? ? 'not available' : "#{score} out of 100"}", size: 14, style: :bold
      pdf.fill_color MUTED
      pdf.text "#{gaps} #{gaps == 1 ? 'issue' : 'issues'} found across #{pages} #{pages == 1 ? 'page' : 'pages'}",
               size: 10
      pdf.move_down 4

      # Before the findings, not after. A reader who only takes in the first
      # paragraph should still leave knowing what is wrong and what it costs,
      # and on a skimmed page that is most readers.
      # The view already computed this from the full report. Recomputing it here
      # would rebuild the client version from a payload with the weights removed,
      # which is how the findings lost their ranking.
      overview = @report['summary'].presence || SeoReportSummary.call(@report)
      if overview.present?
        pdf.move_down 8
        pdf.fill_color INK
        pdf.text overview, size: 10.5, leading: 2
        pdf.move_down 2
      end

      # Said plainly rather than buried, since it changes how much of this to
      # trust and a reader deserves to know before the findings.
      if @report['from_archive']
        pdf.text 'This site blocks automated readers, so the review used the most recent public ' \
                 'archive of it. A few findings may be out of date.', size: 8, style: :italic
      end
      pdf.move_down 16
    end

    def findings(pdf)
      checks = Array(@report['checks'])
      if checks.empty?
        pdf.fill_color MUTED
        pdf.text 'No findings recorded.', size: 10
        return
      end

      checks.each do |check|
        pdf.start_new_page if pdf.cursor < 110

        status = check['status'].to_s
        pdf.fill_color STATUS_COLOR[status] || MUTED
        pdf.text STATUS_LABEL[status] || status.upcase, size: 7, style: :bold

        pdf.fill_color INK
        pdf.text check['label'].to_s, size: 12, style: :bold
        pdf.text check['headline'].to_s, size: 10

        if check['detail'].present?
          pdf.fill_color MUTED
          pdf.text check['detail'].to_s, size: 9
        end

        # Internal only. The addresses are what make this a work order, and a
        # work order in a prospect's hands is free labour for their incumbent.
        if client?
          count = check['affected_count'].to_i
          if count.positive?
            pdf.move_down 3
            pdf.fill_color MUTED
            pdf.text "Affects #{count} #{count == 1 ? 'page' : 'pages'}", size: 8
          end
        else
          urls = Array(check['urls']).first(8)
          if urls.any?
            pdf.move_down 4
            pdf.fill_color MUTED
            urls.each { |url| pdf.text url.to_s, size: 7.5 }
          end
        end

        pdf.move_down 14
      end
    end

    # Only on the client version, and the whole point of it: reframe the report
    # from a list of faults into the size of the gap. A dealer who reads "here
    # is what is wrong" goes to their web guy. One who reads "here is the
    # distance between where you are and where you would be" comes to us.
    def closing(pdf)
      return unless client?

      pdf.move_down 8
      pdf.stroke_color 'DDDDDD'
      pdf.stroke_horizontal_rule
      pdf.move_down 12

      pdf.fill_color INK
      pdf.text "What a #{@brand.name} site scores", size: 12, style: :bold
      pdf.fill_color MUTED
      pdf.text "Sites we build are marked up for search and for AI assistants from the day they " \
               "go live: every home gets its own page, its own price in search results, and a " \
               "dealership listing search engines can read. On this same review they score in " \
               "the nineties.", size: 9.5
      pdf.move_down 8
      pdf.text "Ask us for a walkthrough of what that would look like for #{@report['domain']}.", size: 9.5
    end

    def footer(pdf)
      pdf.repeat(:all) do
        pdf.bounding_box([pdf.bounds.left, pdf.bounds.bottom + 24], width: pdf.bounds.width, height: 24) do
          pdf.fill_color MUTED
          pdf.text "Prepared by #{@brand.name} · #{@brand.website_url}", size: 8
        end
      end
    end

    # Same approach as the quote generator: local uploads first, then HTTP with
    # a couple of redirects. Never fatal, since a report without a logo is still
    # a report.
    def load_image(url)
      return nil if url.blank?
      return nil unless url.start_with?('http://', 'https://')

      uri = URI.parse(url)
      3.times do
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 10
        response = http.request(Net::HTTP::Get.new(uri.request_uri))

        case response
        when Net::HTTPSuccess then return response.body
        when Net::HTTPRedirection then uri = URI.parse(response['location'])
        else return nil
        end
      end
      nil
    rescue StandardError => e
      Rails.logger.warn("[SeoReportPdf] logo failed: #{e.message}")
      nil
    end
  end
end
