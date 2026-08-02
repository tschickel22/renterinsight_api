# frozen_string_literal: true

module Public
  # Serves a tenant's website on the tenant's own hostname.
  #
  # Rails answers here rather than the SPA host because Cloudflare for SaaS forwards the
  # visitor's original Host header, and because search engines need the title, description,
  # canonical and Open Graph tags present in the first response. A single-page app cannot
  # set those early enough to be reliable.
  #
  # The page body still comes from the existing React renderer. There is deliberately no
  # server-side reimplementation of its 28 block types: several are interactive and the rest
  # would drift from the editor preview the first time either side changed. When prerendered
  # HTML exists for a page it is used instead, which is the upgrade path to fully static
  # pages without changing anything here.
  class SitesController < ActionController::Base
    skip_before_action :verify_authenticity_token

    before_action :resolve_site

    def show
      html = prerendered_body || spa_shell
      return render_unavailable if html.nil?

      render html: inject_head(html).html_safe, content_type: 'text/html' # rubocop:disable Rails/OutputSafety
    end

    # GET /robots.txt on a tenant hostname.
    #
    # Served per site rather than from a static file: an unpublished or noindex site must
    # not invite crawlers, and the sitemap line has to point at the dealer's own host.
    def robots
      if @metadata[:robots].to_s.start_with?('noindex')
        return render plain: "User-agent: *\nDisallow: /\n", content_type: 'text/plain'
      end

      body = <<~ROBOTS
        User-agent: *
        Allow: /

        Sitemap: https://#{@canonical_host}/sitemap.xml
      ROBOTS

      render plain: body, content_type: 'text/plain'
    end

    def sitemap
      pages = visible_pages

      xml = +%(<?xml version="1.0" encoding="UTF-8"?>\n)
      xml << %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
      pages.each do |page|
        xml << "  <url>\n"
        xml << "    <loc>#{ERB::Util.html_escape(page_url(page))}</loc>\n"
        xml << "    <lastmod>#{(page.updated_at || @website.updated_at).to_date.iso8601}</lastmod>\n"
        xml << "  </url>\n"
      end
      xml << "</urlset>\n"

      render xml: xml, content_type: 'application/xml'
    end

    private

    def resolve_site
      resolution = Websites::HostResolver.call(request.host)
      return render_not_found if resolution.nil?

      @website = resolution.website
      @canonical_host = resolution.canonical_host
      @page = find_page
      @metadata = Websites::PageMetadata.new(
        website: @website, page: @page, canonical_host: @canonical_host
      ).to_h
    end

    def find_page
      path = normalized_path
      pages = @website.website_pages.where(is_deleted: [false, nil])

      pages.find_by(path: path) ||
        pages.find_by(path: path.delete_prefix('/')) ||
        (path == '/' ? pages.order(:order).first : nil)
    end

    def normalized_path
      path = request.path.presence || '/'
      path = path.chomp('/') if path.length > 1
      path.presence || '/'
    end

    def visible_pages
      @website.website_pages
              .where(is_deleted: [false, nil], is_visible: true)
              .order(:order)
    end

    def page_url(page)
      path = page.path.to_s
      path = "/#{path}" unless path.start_with?('/')
      path = '' if path == '/'
      "https://#{@canonical_host}#{path}"
    end

    # Seam for prerendered static HTML. Nothing writes this yet; when a publish-time
    # prerender step exists it stores HTML here and these pages become fully static with no
    # change to routing, resolution or metadata.
    def prerendered_body
      return nil if @page.nil?
      return nil unless @page.respond_to?(:prerendered_html)

      @page.prerendered_html.presence
    end

    def spa_shell
      Websites::SpaShell.fetch
    rescue Websites::SpaShell::ShellUnavailable => e
      Rails.logger.error("[Public::Sites] #{request.host}: #{e.message}")
      nil
    end

    # Replaces the shell's own title and injects the tags a crawler reads. Existing title
    # and description tags are removed first so the document does not end up with two.
    def inject_head(html)
      doc = html.sub(%r{<title>.*?</title>}im, '')
                .sub(%r{<meta\s+name=["']description["'][^>]*>}i, '')

      doc.sub(%r{<head([^>]*)>}i) { "<head#{Regexp.last_match(1)}>\n#{head_tags}" }
    end

    def head_tags
      tags = []
      tags << tag(:title, @metadata[:title])
      tags << meta_tag('description', @metadata[:description])
      tags << meta_tag('robots', @metadata[:robots])
      tags << link_tag('canonical', @metadata[:canonical_url])
      tags << link_tag('icon', @metadata[:favicon_url])
      tags << property_tag('og:title', @metadata[:title])
      tags << property_tag('og:description', @metadata[:description])
      tags << property_tag('og:url', @metadata[:canonical_url])
      tags << property_tag('og:type', @metadata[:og_type])
      tags << property_tag('og:site_name', @metadata[:site_name])
      tags << property_tag('og:image', @metadata[:og_image])
      tags << meta_tag('twitter:card', @metadata[:og_image].present? ? 'summary_large_image' : 'summary')
      tags.compact.join("\n")
    end

    def tag(name, value)
      return nil if value.blank?

      "<#{name}>#{ERB::Util.html_escape(value)}</#{name}>"
    end

    def meta_tag(name, value)
      return nil if value.blank?

      %(<meta name="#{name}" content="#{ERB::Util.html_escape(value)}">)
    end

    def property_tag(property, value)
      return nil if value.blank?

      %(<meta property="#{property}" content="#{ERB::Util.html_escape(value)}">)
    end

    def link_tag(rel, href)
      return nil if href.blank?

      %(<link rel="#{rel}" href="#{ERB::Util.html_escape(href)}">)
    end

    def render_not_found
      render plain: 'Site not found', status: :not_found
    end

    def render_unavailable
      render plain: 'Site temporarily unavailable', status: :service_unavailable
    end
  end
end
