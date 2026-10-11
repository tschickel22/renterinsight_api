# frozen_string_literal: true

module SiteProfiles
  # Whether a site can measure what its advertising buys.
  #
  # A dealer paying one company for a website and another for ads usually
  # assumes the two are wired together. Often they are not: the old Easy
  # Homesource site carried a Google Ads tag and a conversion label but no
  # analytics at all, so the ads could be optimised and nobody could see where
  # visitors came from or where they left. Finding that on a prospect's site is
  # worth a call on its own.
  #
  # Reads the same HTML the audit graded. It reports what is visibly installed
  # and says what it cannot see: tags a Tag Manager container fires, or ones
  # bundled into a site's own JavaScript, do not appear in the page source.
  #
  # Kept out of both scores. The scores measure whether search engines and
  # assistants can read a site, and a missing pixel does not change that.
  module TrackingChecks
    CATEGORY = 'tracking'

    # vendor => [kind, pattern that shows it is installed, pattern capturing its id]
    TAGS = {
      'Google Analytics 4' => [:analytics, %r{gtag/js\?id=G-|gtag\(\s*['"]config['"]\s*,\s*['"]G-}i,
                               /\b(G-[A-Z0-9]{6,12})\b/],
      'Google Tag Manager' => [:analytics, %r{googletagmanager\.com/gtm\.js|\bGTM-[A-Z0-9]{4,}\b}, /\b(GTM-[A-Z0-9]{4,})\b/],
      'Google Ads' => [:ads, /\bAW-\d{6,12}\b/, /\b(AW-\d{6,12})\b/],
      'Meta Pixel' => [:ads, %r{connect\.facebook\.net/[^"']*fbevents\.js|fbq\(\s*['"]init}i,
                       /fbq\(\s*['"]init['"]\s*,\s*['"](\d{8,20})['"]/],
      'TikTok Pixel' => [:ads, %r{analytics\.tiktok\.com|ttq\.load\(}i, /ttq\.load\(\s*['"]([A-Z0-9]{15,30})['"]/i],
      'Snapchat Pixel' => [:ads, %r{sc-static\.net/scevent|snaptr\(}i, /snaptr\(\s*['"]init['"]\s*,\s*['"]([0-9a-f-]{36})['"]/i],
      'Pinterest Tag' => [:ads, %r{s\.pinimg\.com/ct/core\.js|pintrk\(}i, /pintrk\(\s*['"]load['"]\s*,\s*['"](\d{10,16})['"]/],
      'LinkedIn Insight' => [:ads, %r{snap\.licdn\.com/li\.lms-analytics|_linkedin_partner_id}i,
                             /_linkedin_partner_id\s*=\s*['"](\d{4,10})['"]/],
      'X (Twitter) Pixel' => [:ads, %r{static\.ads-twitter\.com/uwt\.js|twq\(}i, /twq\(\s*['"]config['"]\s*,\s*['"]([a-z0-9]{4,10})['"]/i],
      'Reddit Pixel' => [:ads, %r{redditstatic\.com/ads/pixel\.js|rdt\(\s*['"]init}i, /rdt\(\s*['"]init['"]\s*,\s*['"]([at]2_[a-z0-9]+)['"]/i],
      'Microsoft Ads (UET)' => [:ads, %r{bat\.bing\.com/bat\.js}i, /\bti\s*:\s*['"](\d{5,12})['"]/],
      'Microsoft Clarity' => [:behavior, %r{clarity\.ms/tag}i, %r{clarity\.ms/tag/([a-z0-9]{6,14})|["']clarity["']\s*,\s*["']script["']\s*,\s*["']([a-z0-9]{6,14})["']}i],
      'Hotjar' => [:behavior, %r{static\.hotjar\.com|hotjar\.com/c/}i, /hjid\s*[:=]\s*(\d{5,12})/],
      'LogRocket' => [:behavior, %r{cdn\.(?:lr-ingest|lrkt-in|logrocket)\.(?:com|io)}i, %r{LogRocket\.init\(\s*['"]([a-z0-9]+/[a-z0-9_-]+)['"]}i]
    }.freeze

    # What reports a lead or a sale, rather than a page view.
    CONVERSIONS = {
      'Google Ads conversion' => %r{send_to['"]?\s*:\s*['"]AW-\d+/[\w-]+|['"]AW-\d+/[\w-]{6,}['"]|gtag\(\s*['"]event['"]\s*,\s*['"]conversion['"]}i,
      'GA4 lead event' => /gtag\(\s*['"]event['"]\s*,\s*['"](?:generate_lead|sign_up|purchase|form_submit)['"]/i,
      'Meta lead event' => /fbq\(\s*['"]track['"]\s*,\s*['"](?:Lead|CompleteRegistration|Contact|SubmitApplication|Schedule|Purchase)['"]/,
      'TikTok conversion' => /ttq\.track\(\s*['"](?:SubmitForm|Contact|CompleteRegistration|PlaceAnOrder|CompletePayment|Lead)['"]/i,
      'LinkedIn conversion' => /lintrk\(\s*['"]track['"]\s*,\s*\{\s*conversion_id/i,
      'Microsoft Ads conversion' => /uetq\.push\(\s*['"]event['"]/i,
      'Snapchat conversion' => /snaptr\(\s*['"]track['"]\s*,\s*['"](?:SIGN_UP|PURCHASE|SUBSCRIBE|SAVE|CUSTOM_EVENT_\d)['"]/i,
      'Pinterest conversion' => /pintrk\(\s*['"]track['"]\s*,\s*['"](?:lead|signup|checkout)['"]/i
    }.freeze

    BLIND_SPOT = 'Read from the pages themselves: anything a Tag Manager container fires, or a site bundles ' \
                 'into its own JavaScript, does not show in the page source and cannot be confirmed here.'

    private

    def tracking_checks
      [analytics_tracking_check, ad_tracking_check, conversion_tracking_check].compact
    end

    # vendor => sorted ids seen (empty when the tag shows but its id does not)
    def tracking_found
      @tracking_found ||= begin
        source = @pages_html.values.join("\n")
        TAGS.each_with_object({}) do |(vendor, (_kind, present, id_pattern)), found|
          next unless source.match?(present)

          found[vendor] = source.scan(id_pattern).flatten.compact.map(&:to_s).uniq.sort
        end
      end
    end

    def conversions_found
      @conversions_found ||= begin
        source = @pages_html.values.join("\n")
        CONVERSIONS.select { |_, pattern| source.match?(pattern) }.keys
      end
    end

    def tracking_of(kind)
      tracking_found.select { |vendor, _| TAGS.dig(vendor, 0) == kind }
    end

    def describe_tags(found)
      found.map { |vendor, ids| ids.any? ? "#{vendor} (#{ids.join(', ')})" : vendor }.join(', ')
    end

    def tracking_check(key, label, status, headline, detail = nil)
      SeoAudit::Check.new(key: key, label: label, status: status, headline: headline, detail: detail,
                          urls: [], weight: 0, category: CATEGORY)
    end

    def analytics_tracking_check
      found = tracking_of(:analytics)
      if found.any?
        return tracking_check('analytics_tracking', 'Analytics', 'pass', describe_tags(found))
      end

      ads = tracking_of(:ads)
      tracking_check('analytics_tracking', 'Analytics', 'fail', 'No analytics installed',
                     (ads.any? ? "Ads are tagged (#{ads.keys.join(', ')}) but there is no analytics behind them, " : '') +
                     'so nobody can see where visitors come from, which pages they read or where they ' \
                     'leave. Google Analytics 4 is free and takes minutes to add. ' + BLIND_SPOT)
    end

    def ad_tracking_check
      found = tracking_of(:ads)
      if found.any?
        return tracking_check('ad_tracking', 'Advertising tags', 'pass', describe_tags(found))
      end

      tracking_check('ad_tracking', 'Advertising tags', 'warn', 'No ad platform tags',
                     'Nothing from Google Ads, Meta, TikTok or any other ad platform is on the site. If the ' \
                     'dealership advertises, those clicks cannot be measured or retargeted. ' + BLIND_SPOT)
    end

    def conversion_tracking_check
      if conversions_found.any?
        return tracking_check('conversion_tracking', 'Conversion tracking', 'pass',
                              "Reports leads: #{conversions_found.join(', ')}")
      end

      ads = tracking_of(:ads)
      gtm = tracking_found.key?('Google Tag Manager')
      if ads.empty? && !gtm
        return tracking_check('conversion_tracking', 'Conversion tracking', 'fail', 'Nothing reports a lead',
                              'No ad platform is told when someone submits a form or calls, so ad spend is ' \
                              'optimised blind, if at all. ' + BLIND_SPOT)
      end

      tracking_check('conversion_tracking', 'Conversion tracking', 'warn',
                     'Tags installed, but no lead event found',
                     "#{describe_tags(ads.presence || tracking_of(:analytics))} " \
                     "#{(ads.presence || tracking_of(:analytics)).size == 1 ? 'is' : 'are'} on the site, but " \
                     'nothing on the pages reports a form submission or a call as a conversion. Ask whoever ' \
                     "runs the ads to confirm conversions are recorded#{gtm ? ' in the Tag Manager container' : ''}. " +
                     BLIND_SPOT)
    end

    def tracking_summary
      {
        'tags' => tracking_found.map { |vendor, ids| { 'vendor' => vendor, 'kind' => TAGS.dig(vendor, 0).to_s, 'ids' => ids } },
        'conversion_events' => conversions_found
      }
    end
  end
end
