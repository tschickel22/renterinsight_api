# frozen_string_literal: true

module Assistant
  # What Quinn AI reads about a dealer besides their own answers (E96,
  # 2026-11-07): the FAQs and About text on the sites we host for them, and the
  # FAQs and About text from their own website, read by the same scanner that
  # builds demos (SiteContentProfile). Shown in Quinn's settings exactly as
  # Quinn sees it, since a hosted site can still carry a template's sample
  # copy, and the dealer can switch website text off.
  module Sources
    MAX_FAQS = 30
    MAX_ABOUT = 1200

    module_function

    def use_websites?(company)
      Assistant::Settings.for(company)['use_website_text'] != false
    end

    # [{ q:, a:, source: }] from the dealer's published sites and their own
    # site's last reading, without repeats.
    def website_faqs(company)
      list = hosted_faqs(company) + scanned_faqs(company)
      list.uniq { |f| f[:q].downcase.gsub(/\W/, '') }.first(MAX_FAQS)
    end

    # { text:, source: } or nil: their own site's About first, then the About
    # page on a site we host.
    def about(company)
      scan = last_scan(company)
      own = Array(scan&.profile&.dig('copy', 'about')).filter_map { |a| a['body'].to_s.squish.presence }.join(' ')
      return { text: own.truncate(MAX_ABOUT), source: host(scan.source_url) } if own.present?

      hosted_sites(company).each do |site|
        page = site.website_pages.where(is_deleted: [false, nil]).find { |p| p.path.to_s.match?(/about/i) || p.title.to_s.match?(/\Aabout/i) }
        next unless page

        text = Array(page.blocks).select { |b| b.is_a?(Hash) && b['type'] == 'text' }
                                 .map { |b| ActionView::Base.full_sanitizer.sanitize(b.dig('content', 'html').to_s).squish }
                                 .join(' ')
        return { text: text.truncate(MAX_ABOUT), source: site.name } if text.present?
      end
      nil
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Sources] about failed for company #{company&.id}: #{e.message}")
      nil
    end

    def hosted_sites(company)
      company.websites.sites.where(status: :published, is_deleted: [false, nil]).order(:id).to_a
    end

    def hosted_faqs(company)
      hosted_sites(company).flat_map do |site|
        site.website_pages.where(is_deleted: [false, nil]).flat_map do |page|
          Array(page.blocks).select { |b| b.is_a?(Hash) && b['type'] == 'faq' }.flat_map do |block|
            Array(block.dig('content', 'faqs')).filter_map do |f|
              q = f['question'].to_s.squish
              a = ActionView::Base.full_sanitizer.sanitize(f['answer'].to_s).squish
              { q: q.truncate(300), a: a.truncate(600), source: site.name } if q.present? && a.present?
            end
          end
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Sources] hosted FAQs failed for company #{company&.id}: #{e.message}")
      []
    end

    def scanned_faqs(company)
      scan = last_scan(company)
      return [] unless scan

      Array(scan.profile&.dig('copy', 'faq')).filter_map do |f|
        q = f['question'].to_s.squish
        a = f['answer'].to_s.squish
        { q: q.truncate(300), a: a.truncate(600), source: host(scan.source_url) } if q.present? && a.present?
      end
    end

    # The latest finished reading of one of the dealer's own sites (a site
    # listed for the chat, or the one they asked Quinn to read).
    def last_scan(company)
      sites = Assistant::Settings.for(company).chat_sites
      reading = Assistant::Settings.for(company)['site_reading_id']
      scope = SiteContentProfile.where(company_id: company.id, status: 'ready', source_kind: 'url')
      (reading && scope.find_by(id: reading)) ||
        scope.order(updated_at: :desc).detect { |p| sites.include?(Assistant::Settings.normalize_host(p.source_url)) }
    rescue StandardError
      nil
    end

    # Starts a reading of the dealer's own site with the demo scanner.
    def read_site!(company, url, user)
      url = url.to_s.strip
      url = "https://#{url}" unless url.match?(%r{\Ahttps?://}i)
      SiteProfiles::UrlGuard.validate!(url)
      profile = SiteContentProfile.create!(company_id: company.id, created_by: user, source_url: url,
                                           display_name: "#{Assistant::Settings.for(company).assistant_name} AI reading", status: 'pending')
      SiteProfileScanJob.perform_later(profile.id)
      Assistant::Settings.for(company).update!('site_reading_id' => profile.id)
      profile
    end

    def reading_status(company)
      id = Assistant::Settings.for(company)['site_reading_id']
      profile = id && SiteContentProfile.find_by(id: id, company_id: company.id)
      return nil unless profile

      { url: profile.source_url, status: profile.status, read_at: profile.updated_at,
        faqs: Array(profile.profile&.dig('copy', 'faq')).size, error: profile.status == 'failed' ? profile.error_message.to_s.truncate(200) : nil }
    end

    def host(url)
      Assistant::Settings.normalize_host(url) || url.to_s
    end

    # The lines Quinn reads (Brain).
    def prompt_lines(company)
      return '' unless use_websites?(company)

      about_text = about(company)
      faqs = website_faqs(company)
      lines = []
      lines << "About the dealership: #{about_text[:text]}" if about_text
      lines += faqs.map { |f| "Q: #{f[:q]}\n  A: #{f[:a]}" }
      lines.join("\n")
    end
  end
end
