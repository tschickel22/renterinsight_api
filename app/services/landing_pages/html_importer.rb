# frozen_string_literal: true

require 'nokogiri'
require 'zip'
require 'net/http'
require 'base64'

module LandingPages
  # Bring a page designed elsewhere in as itself.
  #
  # The block importer reproduces CONTENT in our design system: a process step
  # is a 48px circle filled with the site primary because that is how we draw
  # one, and no amount of importing changes that. For a marketing page where the
  # design is the pitch, that ceiling is the wrong trade. This keeps the design
  # and gives up block editing instead.
  #
  # Two things have to happen for that to be safe and durable:
  #
  #   Assets are rehosted. A design arrives with its images inlined as data URIs
  #   or sitting next to it in a zip. Left alone the first bloats every response
  #   with megabytes of base64 and the second simply 404s. Each one is uploaded
  #   to our own storage and the reference rewritten, so the page ends up
  #   pointing at the CDN like everything else we serve.
  #
  #   Scripts are removed. This HTML is rendered into a page we serve, so
  #   anything executable in it runs with our origin. Presentation is kept in
  #   full , style elements, inline styles, classes, layout , because that is
  #   the entire reason for this path. Behaviour is not.
  #
  # A design that builds its DOM at runtime (React compiled in the browser, say)
  # therefore arrives blank, and that is the honest outcome rather than a
  # surprise: export a static page.
  class HtmlImporter
    class ImportError < StandardError; end

    MAX_SOURCE_BYTES = 40.megabytes
    # After rehosting there should be no base64 left, so anything still this
    # large is a design carrying something we did not recognise.
    MAX_HTML_BYTES = 2.megabytes
    MAX_ASSET_BYTES = 25.megabytes
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20
    FOLDER = 'landing-imports'

    EXTENSIONS = {
      'image/jpeg' => '.jpg', 'image/jpg' => '.jpg', 'image/png' => '.png',
      'image/webp' => '.webp', 'image/gif' => '.gif', 'image/avif' => '.avif',
      'image/svg+xml' => '.svg', 'video/mp4' => '.mp4', 'video/webm' => '.webm'
    }.freeze

    # Attributes that can carry a URL we should bring across.
    URL_ATTRS = %w[src poster data-src].freeze

    # Anything that executes. Removed wholesale.
    SCRIPTABLE = %w[script noscript object embed applet].freeze

    Result = Struct.new(:html, :imported, :skipped, :warnings, :video_slots, keyword_init: true)

    # A Struct rather than an uploaded file, so S3UploadService treats a decoded
    # asset exactly like a browser upload.
    Asset = Struct.new(:body, :content_type, :original_filename) do
      def read = body
      def size = body.bytesize
      def path = original_filename
    end

    def initialize(company:, website:, uploader: S3UploadService.new, logger: Rails.logger)
      @company = company
      @website = website
      @uploader = uploader
      @logger = logger
      @map = {}
      @warnings = []
      @skipped = 0
      @video_slots = []
    end

    # @param upload [ActionDispatch::Http::UploadedFile] an .html or .zip
    def call(upload)
      raise ImportError, 'No file was uploaded.' unless upload.respond_to?(:read)
      raise ImportError, "That file is larger than #{MAX_SOURCE_BYTES / 1.megabyte}MB." if
        upload.size.to_i > MAX_SOURCE_BYTES

      source, entries = read_source(upload)
      raise ImportError, 'No HTML was found in that file.' if source.blank?

      doc = Nokogiri::HTML5(source) || Nokogiri::HTML(source)
      # Before scripts are stripped, because a YouTube or Vimeo embed is an
      # iframe and strip_executable is what decides which iframes survive.
      claim_video_slots(doc)
      strip_executable(doc)
      rewrite_assets(doc, entries)
      rewrite_style_urls(doc, entries)

      html = extract_body(doc)
      if html.bytesize > MAX_HTML_BYTES
        raise ImportError,
              'That page is still too large after its images were moved to storage. ' \
              'It is probably carrying embedded fonts or video that need to be linked instead.'
      end

      Result.new(html: html, imported: @map.values.compact.uniq.size,
                 skipped: @skipped, warnings: @warnings.uniq, video_slots: @video_slots)
    end

    private

    # Turn every video in the design into a slot we can fill later.
    #
    # A design uses a YouTube or Vimeo embed because that is what a design tool
    # can show, but shipping it means the player's own chrome, its related-video
    # suggestions and its cookies on a page whose whole job is to convert. The
    # embed is replaced in place with an empty video element and recorded as a
    # slot, so the author can point it at an MP4 in their own media library and
    # the page serves it from our CDN instead.
    #
    # Replaced in place rather than unwrapped: an embed is nearly always inside
    # an aspect-ratio box, and the sizing belongs to the design. The element's
    # own class, style and dimensions are carried across for the same reason.
    def claim_video_slots(doc)
      nodes = doc.css('iframe').select { |n| video_host(n['src']) } + doc.css('video')

      nodes.each_with_index do |node, index|
        slot = "v#{index + 1}"
        source = node.name == 'iframe' ? video_host(node['src']) : 'file'
        original = node.name == 'iframe' ? node['src'].to_s : node['src'].to_s

        replacement = Nokogiri::XML::Node.new('video', doc)
        replacement['data-dt-slot'] = slot
        replacement['controls'] = 'controls'
        replacement['playsinline'] = 'playsinline'
        replacement['preload'] = 'metadata'
        # A slot with nothing in it yet must not be a black rectangle in the
        # middle of the page, so it says what it is until it is filled.
        replacement['style'] = [node['style'], 'width:100%;height:100%;background:#111;display:block']
                               .compact.reject(&:empty?).join(';')
        replacement['class'] = node['class'] if node['class'].present?
        replacement['width'] = node['width'] if node['width'].present?
        replacement['height'] = node['height'] if node['height'].present?
        replacement['poster'] = node['poster'] if node['poster'].present?

        node.replace(replacement)
        @video_slots << { 'id' => slot, 'source' => source, 'original_url' => original }
      end

      return if @video_slots.empty?

      @warnings << "#{@video_slots.size} video#{'s' if @video_slots.size != 1} became empty " \
                   'slots. Point each one at an MP4 in your media library.'
    end

    def video_host(src)
      case src.to_s
      when %r{\Ahttps?://(www\.)?(youtube(-nocookie)?\.com|youtu\.be)/}i then 'youtube'
      when %r{\Ahttps?://(player\.)?vimeo\.com/}i then 'vimeo'
      end
    end

    # A bare .html, or a zip holding one plus its assets.
    #
    # Returns the markup and, for a zip, the other entries keyed by the path the
    # markup will refer to them by.
    def read_source(upload)
      bytes = upload.read
      bytes = bytes.dup.force_encoding(Encoding::UTF_8)

      return [bytes, {}] unless zip?(upload, bytes)

      entries = {}
      html = nil
      html_name = nil

      Zip::File.open_buffer(bytes.b) do |zip|
        # index.html wins; otherwise the first .html at the shallowest depth, so
        # a stray fixture in a subfolder does not beat the real page.
        candidates = zip.entries.select { |e| e.file? && e.name =~ /\.html?\z/i }
        chosen = candidates.find { |e| File.basename(e.name).casecmp('index.html').zero? } ||
                 candidates.min_by { |e| [e.name.count('/'), e.name] }
        raise ImportError, 'That zip has no HTML file in it.' if chosen.nil?

        html_name = chosen.name
        html = chosen.get_input_stream.read.force_encoding(Encoding::UTF_8)

        zip.entries.each do |entry|
          next unless entry.file?
          next if entry.name == html_name
          next if entry.size > MAX_ASSET_BYTES

          entries[normalize_path(entry.name)] = entry.get_input_stream.read
        end
      end

      # References are relative to the HTML file, so a page in a subfolder needs
      # its own directory stripped back off the keys to match.
      base = File.dirname(html_name)
      unless base == '.'
        entries = entries.transform_keys { |k| k.delete_prefix("#{base}/") }
      end

      [html, entries]
    rescue Zip::Error => e
      raise ImportError, "That zip could not be read: #{e.message}"
    end

    def zip?(upload, bytes)
      return true if upload.original_filename.to_s.downcase.end_with?('.zip')

      bytes.byteslice(0, 2) == 'PK'.b || bytes.dup.b.byteslice(0, 2) == 'PK'.b
    end

    def normalize_path(path)
      path.to_s.sub(%r{\A\./}, '').sub(%r{\A/}, '')
    end

    # Presentation stays, behaviour goes.
    def strip_executable(doc)
      removed = 0

      doc.css(SCRIPTABLE.join(',')).each do |node|
        removed += 1
        node.remove
      end

      doc.traverse do |node|
        next unless node.element?

        node.attribute_nodes.each do |attr|
          name = attr.name.to_s.downcase
          # onclick, onload and friends.
          if name.start_with?('on')
            attr.remove
            removed += 1
            next
          end
          # javascript: in an href or a src.
          attr.remove if attr.value.to_s.strip.downcase.start_with?('javascript:')
        end
      end

      # An iframe can load anything, including something that frames us back.
      doc.css('iframe').each do |frame|
        src = frame['src'].to_s
        next if src.match?(%r{\Ahttps://(www\.)?(youtube(-nocookie)?\.com|player\.vimeo\.com)/}i)

        frame.remove
        removed += 1
      end

      @warnings << "Removed #{removed} script or interactive element#{'s' unless removed == 1}." if removed.positive?
    end

    def rewrite_assets(doc, entries)
      doc.css('img, source, video, audio').each do |node|
        URL_ATTRS.each do |attr|
          value = node[attr]
          next if value.blank?

          rehosted = import(value, entries)
          node[attr] = rehosted if rehosted
        end

        next if node['srcset'].blank?

        node['srcset'] = node['srcset'].split(',').map do |candidate|
          url, descriptor = candidate.strip.split(/\s+/, 2)
          rehosted = import(url, entries)
          [rehosted || url, descriptor].compact.join(' ')
        end.join(', ')
      end
    end

    # url(...) inside a style element or a style attribute.
    def rewrite_style_urls(doc, entries)
      doc.css('style').each { |node| node.content = rewrite_css(node.content, entries) }

      doc.css('[style]').each do |node|
        node['style'] = rewrite_css(node['style'], entries)
      end
    end

    def rewrite_css(css, entries)
      css.to_s.gsub(/url\(\s*(['"]?)([^'")]+)\1\s*\)/i) do
        quote = Regexp.last_match(1)
        url = Regexp.last_match(2)
        rehosted = import(url, entries)
        "url(#{quote}#{rehosted || url}#{quote})"
      end
    end

    # Returns our URL for an asset, or nil to leave the reference alone.
    def import(url, entries)
      return @map[url] if @map.key?(url)

      asset = load_asset(url, entries)
      return @map[url] = nil if asset.nil?

      uploaded = @uploader.upload(asset, folder: "#{FOLDER}/#{@website.id}")
      record_media(uploaded, asset)
      @map[url] = media_url(uploaded)
    rescue StandardError => e
      @logger.warn("[LandingPages::HtmlImporter] #{url.to_s.first(80)}: #{e.class}: #{e.message}")
      @warnings << 'An image could not be brought across and still points at its original location.'
      @skipped += 1
      @map[url] = nil
    end

    def load_asset(url, entries)
      value = url.to_s.strip
      return nil if value.blank? || value.start_with?('#')

      if value.start_with?('data:')
        decode_data_uri(value)
      elsif value.match?(%r{\Ahttps?://})
        already_ours?(value) ? nil : fetch_remote(value)
      else
        from_zip(value, entries)
      end
    end

    def decode_data_uri(value)
      match = value.match(%r{\Adata:([^;,]+)(;base64)?,(.*)\z}m)
      return nil if match.nil?

      content_type = match[1].to_s.downcase
      extension = EXTENSIONS[content_type]
      unless extension
        @warnings << "Skipped an embedded #{content_type.presence || 'unknown'} asset."
        @skipped += 1
        return nil
      end

      body = match[2] ? Base64.decode64(match[3]) : CGI.unescape(match[3])
      return nil if body.empty?

      if body.bytesize > MAX_ASSET_BYTES
        @warnings << "Skipped an embedded asset over #{MAX_ASSET_BYTES / 1.megabyte}MB."
        @skipped += 1
        return nil
      end

      Asset.new(body: body, content_type: content_type,
                original_filename: "embedded-#{SecureRandom.hex(4)}#{extension}")
    end

    def from_zip(value, entries)
      key = normalize_path(value.split('?').first.split('#').first)
      body = entries[key]
      if body.nil?
        @warnings << "#{File.basename(key)} was referenced but is not in the zip."
        @skipped += 1
        return nil
      end

      content_type = EXTENSIONS.key(File.extname(key).downcase) || 'application/octet-stream'
      Asset.new(body: body, content_type: content_type, original_filename: File.basename(key))
    end

    def fetch_remote(value)
      uri, = SiteProfiles::UrlGuard.validate!(value)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      response = http.request(Net::HTTP::Get.new(uri))
      return nil unless response.is_a?(Net::HTTPSuccess)

      content_type = response['content-type'].to_s.split(';').first&.strip&.downcase
      extension = EXTENSIONS[content_type]
      return nil if extension.nil?

      body = response.body.to_s
      return nil if body.empty? || body.bytesize > MAX_ASSET_BYTES

      base = File.basename(uri.path.to_s, '.*').presence || 'image'
      Asset.new(body: body, content_type: content_type,
                original_filename: "#{base.parameterize.presence || 'image'}#{extension}")
    rescue StandardError
      # A remote image that will not come across keeps its original URL, which
      # at least still renders while the dealer's old host is up.
      nil
    end

    def already_ours?(url)
      bucket = ENV['AWS_S3_BUCKET'].presence
      cdn = ENV['CDN_DOMAIN'].presence
      (bucket.present? && url.include?(bucket)) || (cdn.present? && url.include?(cdn))
    end

    def record_media(uploaded, asset)
      WebsiteMedia.create!(
        company_id: @company.id,
        website_id: @website.id,
        name: asset.original_filename,
        url: uploaded[:url],
        s3_key: uploaded[:key],
        s3_bucket: ENV['AWS_S3_BUCKET'].presence,
        mime_type: asset.content_type,
        file_size: asset.size,
        file_type: asset.content_type.start_with?('video/') ? :video : :image
      )
    rescue StandardError => e
      # The upload succeeded; a bookkeeping failure must not lose the asset.
      @logger.warn("[LandingPages::HtmlImporter] media row: #{e.message}")
      nil
    end

    # Prefer the CDN, exactly as WebsiteMedia#full_url would.
    def media_url(uploaded)
      cdn = ENV['CDN_DOMAIN'].presence&.sub(%r{\Ahttps?://}, '')&.delete_suffix('/')
      return uploaded[:url] if cdn.blank? || uploaded[:key].blank?

      "https://#{cdn}/#{uploaded[:key]}"
    end

    # Style elements live in head and have to survive, so the body alone is not
    # enough. Head styles and webfont links are moved inline ahead of the markup
    # and everything else in head is dropped, since a title or a meta tag
    # belongs to the page we are rendering into, not to this fragment.
    #
    # The font links matter more than they look: a design's typography is most
    # of its character, and dropping the stylesheet silently falls back to a
    # system face, which reads as "the import broke" rather than "the font did
    # not come". Only the font hosts are kept , a stylesheet from anywhere else
    # can restyle the page it is rendered into and is not presentation we asked
    # for.
    FONT_HOSTS = %r{\Ahttps://(fonts\.googleapis\.com|fonts\.gstatic\.com|use\.typekit\.net)/}i

    def extract_body(doc)
      fonts = doc.css('head link[rel="stylesheet"]').select { |l| l['href'].to_s.match?(FONT_HOSTS) }
      styles = doc.css('head style').map(&:to_html)
      body = doc.at_css('body')
      markup = body ? body.inner_html : doc.to_html

      (fonts.map(&:to_html) + styles + [markup]).reject(&:blank?).join("\n")
    end
  end
end
