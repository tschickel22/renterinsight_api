# frozen_string_literal: true

module Websites
  # /llms.txt for a dealer site, in the llmstxt.org shape: a title, a one-line
  # summary, the facts an assistant is most often asked (where, when, how to
  # reach them), then links to what is worth reading.
  #
  # Everything comes from records the site already renders, the same place the
  # page markup does, so this cannot say anything the site does not.
  class LlmsTxt
    DAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
    MAX_HOMES = 25
    MAX_POSTS = 20

    def initialize(website:, canonical_host:)
      @website = website
      @canonical_host = canonical_host
    end

    def call
      out = +"# #{site_name}\n\n"
      out << "> #{summary}\n\n" if summary.present?
      facts = contact_facts
      out << "#{facts.join("\n")}\n\n" if facts.any?

      section(out, 'Pages', page_links)
      section(out, 'Homes for sale', home_links)
      section(out, 'Blog', post_links)
      out << "## Optional\n\n- [Sitemap](#{base_url}/sitemap.xml)\n"
      out
    end

    private

    def base_url = "https://#{@canonical_host}"

    def brand = @brand ||= (@website.brand.presence || {}).deep_stringify_keys

    def seo = @seo ||= (@website.seo_config.presence || {}).deep_stringify_keys

    def company = @website.company

    def site_name
      brand['company_name'].presence || company&.name.presence || @website.name
    end

    def summary
      text = seo['default_description'].presence || seo['description'].presence || brand['description'].presence
      text.to_s.squish.truncate(300).presence
    end

    def place
      @place ||= @website.location&.address_line1.presence ? @website.location : company
    end

    def contact_facts
      street = place.try(:address_line1).presence
      city = [place.try(:city).presence, place.try(:state).presence].compact.join(', ')
      zip = place.try(:zip_code).presence || place.try(:zip).presence
      phone = place.try(:phone).presence || company.try(:phone).presence
      email = place.try(:email).presence || company.try(:email).presence

      [
        (street && "- Address: #{[street, [city.presence, zip].compact.join(' ')].compact.join(', ')}"),
        (street.nil? && city.present? ? "- Location: #{city}" : nil),
        (phone && "- Phone: #{phone}"),
        (email && "- Email: #{email}"),
        (hours_line && "- Hours: #{hours_line}")
      ].compact
    end

    def hours_line
      hours = place.try(:business_hours)
      return nil unless hours.is_a?(Hash)

      parts = DAYS.filter_map do |day|
        spec = hours[day]
        next unless spec.is_a?(Hash)
        next "#{day.capitalize} closed" if ActiveModel::Type::Boolean.new.cast(spec['closed'])

        "#{day.capitalize} #{spec['open']}-#{spec['close']}" if spec['open'].present? && spec['close'].present?
      end
      parts.any? ? parts.join('; ') : nil
    end

    def section(out, title, lines)
      return if lines.empty?

      out << "## #{title}\n\n#{lines.join("\n")}\n\n"
    end

    def link(text, url, note = nil)
      "- [#{text.to_s.squish}](#{url})#{note.present? ? ": #{note.to_s.squish.truncate(160)}" : ''}"
    end

    def page_links
      @website.website_pages.publicly_servable.order(:order).limit(50).filter_map do |p|
        next if p.robots.to_s.include?('noindex') || p.path.blank?

        path = p.path.start_with?('/') ? p.path : "/#{p.path}"
        link(p.title.presence || path, "#{base_url}#{path == '/' ? '' : path}", p.seo_description)
      end
    end

    def home_links
      return [] if company.nil?

      company.vehicles.where(is_deleted: [false, nil], status: HomeUrl::SERVABLE_STATUSES)
             .order(updated_at: :desc).limit(MAX_HOMES).filter_map do |v|
        url = HomeUrl.url_for(v, @canonical_host)
        name = [v.try(:year), v.try(:make), v.try(:model)].compact.join(' ')
        next if url.blank? || name.blank?

        specs = [
          (v.try(:bedrooms).to_f.positive? ? "#{v.bedrooms.to_s.sub(/\.0\z/, '')} bed" : nil),
          (v.try(:bathrooms).to_f.positive? ? "#{v.bathrooms.to_s.sub(/\.0\z/, '')} bath" : nil),
          (v.try(:square_feet).to_i.positive? ? "#{v.square_feet} sq ft" : nil),
          (v.try(:sale_price).to_f.positive? ? "$#{ActiveSupport::NumberHelper.number_to_delimited(v.sale_price.to_i)}" : nil)
        ].compact
        link(name, url, specs.join(', '))
      end
    rescue StandardError
      []
    end

    def post_links
      base = BlogPostUrl.blog_page_path(@website)
      return [] if base.blank?

      @website.blog_posts.active.published_posts.order(published_at: :desc).limit(MAX_POSTS).map do |p|
        link(p.title, "#{base_url}#{BlogPostUrl.path_for(@website, p, base: base)}", p.excerpt)
      end
    rescue StandardError
      []
    end
  end
end
