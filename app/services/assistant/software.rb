# frozen_string_literal: true

module Assistant
  # Quinn for a software company (industry saas): DealerTide's own website
  # chat (Tom, 2026-11-11). It answers from the product list, the help
  # articles and the training videos instead of homes in stock, never quotes a
  # price (pricing is gone over on the demo), and works toward a demo booked
  # with the person the company chose, on their video meeting link.
  module Software
    ARTICLES = 3
    ARTICLE_CHARS = 900
    VIDEOS = 2

    module_function

    def for?(company)
      company.try(:industry).to_s == 'saas'
    end

    # What the company sells: every add-on with its description, by area.
    def product_lines
      PlatformModule::MODULES.group_by { |_, m| m[:category] }.map do |category, mods|
        undash("#{category}: " + mods.map { |_, m| "#{m[:name]} (#{m[:description]})" }.join('; '))
      end.join("\n")
    end

    # Quinn copies the wording it is given; no dashes reach a customer.
    def undash(text)
      text.to_s.gsub(/\s*[\u2013\u2014]\s*/, ', ')
    end

    # The visitor's last couple of messages: what the articles and videos are
    # looked up by.
    def question_from(history)
      Array(history).select { |c| c.direction == 'inbound' }.last(2).map { |c| c.body.to_s }.join(' ').squish.truncate(400)
    end

    def articles(query)
      return [] if query.blank?

      Guide::HelpSearch.call(query, limit: ARTICLES)
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Software] article search: #{e.class}: #{e.message}")
      []
    end

    def article_lines(query)
      articles(query).map do |a|
        body = undash("#{a.excerpt} #{Knowledge::Screenshot.strip(a.content)}".gsub(/[#*_`>|]/, ' ')).squish.truncate(ARTICLE_CHARS)
        "- #{undash(a.title)}: #{body}"
      end.join("\n")
    end

    # Only videos that are published AND shared: the watch link works for
    # anyone without signing in only when sharing is on.
    def videos(query)
      return [] if query.blank?

      scope = TrainingVideo.published.where(share_enabled: true)
      TrainingVideo.search(query, scope: scope, limit: VIDEOS).map do |video, moment|
        start = moment.to_h[:start].to_i
        { id: video.id, title: undash(video.title), label: undash(moment.to_h[:label]).presence, start: start, url: watch_url(video, start) }
      end
    rescue StandardError => e
      Rails.logger.warn("[Assistant::Software] video search: #{e.class}: #{e.message}")
      []
    end

    def watch_url(video, start = 0)
      base = Brand.app_url.to_s.chomp('/')
      "#{base}/watch/#{video.share_token}#{"?t=#{start}" if start.to_i.positive?}"
    end

    # The button under Quinn's reply in the chat.
    def video_action(video)
      { 'type' => 'link', 'label' => "Watch: #{video[:title]}".truncate(60), 'url' => video[:url] }
    end
  end
end
