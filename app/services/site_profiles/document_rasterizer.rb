# frozen_string_literal: true

require 'open3'
require 'tmpdir'

module SiteProfiles
  # Renders PDF pages to JPEGs so a document can be *seen* rather than only read.
  #
  # pdf-reader recovers text and nothing else. A product sheet is mostly
  # photography, floor plans, spec tables and layout — extract only its text and
  # the model is asked to match a design it was never shown. These rasterised
  # pages go to Claude as image content blocks alongside the text, in the shape
  # Campaigns::AiBuilder already uses for uploaded images.
  #
  # Degrades rather than raises. If pdftoppm is missing or the PDF is malformed
  # the caller gets an empty array and the text-only path still produces a
  # profile — a thinner one, but a profile.
  class DocumentRasterizer
    # Vision cost scales with page count and a spec sheet's useful content is at
    # the front. Eight covers a brochure without turning one upload into a
    # twenty-image request.
    MAX_PAGES = 8

    # Claude downsamples above ~1568px on the long edge, so anything larger is
    # tokens spent to be scaled back down. This keeps spec tables legible while
    # staying under that.
    LONG_EDGE_PX = 1400

    # JPEG, not PNG: a rasterised photo-heavy page is several times larger as
    # PNG, and every byte is base64-inflated into the request.
    JPEG_QUALITY = 80

    # A malformed or adversarial PDF can make pdftoppm spin. This bounds one
    # scan; the orchestrator's own timeout bounds the whole job.
    TIMEOUT_SECONDS = 60

    MEDIA_TYPE = 'image/jpeg'

    class << self
      # @param pdf_bytes [String] raw PDF bytes (binary)
      # @return [Array<Hash>] attachment hashes shaped like Campaigns::AiBuilder's
      #   image uploads: { 'content_type' => 'image/jpeg', 'data_base64' => ...,
      #   'filename' => 'page-1.jpg', 'page' => 1 }
      def call(pdf_bytes, max_pages: MAX_PAGES)
        return [] if pdf_bytes.blank?
        return [] unless pdf?(pdf_bytes)

        unless available?
          Rails.logger.warn('[DocumentRasterizer] pdftoppm not found — falling back to text-only extraction')
          return []
        end

        render_pages(pdf_bytes, max_pages)
      rescue StandardError => e
        Rails.logger.warn("[DocumentRasterizer] rasterization failed: #{e.class}: #{e.message}")
        []
      end

      # Whether page rendering is possible in this environment. Lets callers
      # report "text only" honestly instead of silently producing a thin profile.
      def available?
        return @available unless @available.nil?

        @available = system('which', 'pdftoppm', out: File::NULL, err: File::NULL) || false
      end

      # Test seam — the memoised probe would otherwise persist across examples.
      def reset_availability!
        @available = nil
      end

      private

      def pdf?(bytes)
        bytes[0, 5].to_s.dup.force_encoding('ASCII-8BIT').start_with?('%PDF')
      end

      def render_pages(pdf_bytes, max_pages)
        Dir.mktmpdir('site-profile-raster') do |dir|
          input = File.join(dir, 'input.pdf')
          File.binwrite(input, pdf_bytes)

          # Argument array, never a shell string: the paths are ours but the
          # bytes are not, and this keeps it that way.
          cmd = [
            'pdftoppm', '-jpeg',
            '-jpegopt', "quality=#{JPEG_QUALITY}",
            '-scale-to', LONG_EDGE_PX.to_s,
            '-f', '1', '-l', max_pages.to_s,
            input, File.join(dir, 'page')
          ]

          _out, err, status = Open3.capture3(*cmd, binmode: true)
          unless status.success?
            Rails.logger.warn("[DocumentRasterizer] pdftoppm exited #{status.exitstatus}: #{err.to_s[0, 300]}")
            return []
          end

          collect(dir)
        end
      end

      # pdftoppm zero-pads page numbers based on the total page count, so sort by
      # the parsed integer rather than lexically — otherwise page 10 lands
      # between 1 and 2.
      def collect(dir)
        Dir.glob(File.join(dir, 'page*.jpg'))
           .sort_by { |path| page_number(path) }
           .map do |path|
             {
               'filename' => File.basename(path),
               'content_type' => MEDIA_TYPE,
               'page' => page_number(path),
               'data_base64' => Base64.strict_encode64(File.binread(path))
             }
           end
      end

      def page_number(path)
        File.basename(path)[/(\d+)\.jpg\z/, 1].to_i
      end
    end
  end
end
