# frozen_string_literal: true

require 'open3'
require 'vips'

module Catalog
  module Swatches
    # Reads a factory's decor sheet (the "Interior and Exterior Selections"
    # poster) into swatches: each finish sample cut out of the sheet, with
    # its name, the set it belongs to and its measured color.
    #
    # The samples are found from the pixels (solid blocks on a white page),
    # numbered on the page, and Claude only says which caption belongs to
    # which number. Asked for coordinates itself, Claude's boxes came out
    # shifted by up to half a sample and cut captions and headings instead.
    class SheetReader
      class Error < StandardError; end

      CUT_DPI = 200      # the page the samples are cut from
      FIND_PX = 1000     # width the page is searched at
      MIN_SIDE = 28      # at FIND_PX; anything smaller is text
      INK = 252          # a channel below this is not page background (white samples are faint)
      INSET = 0.05       # share of each edge dropped, clear of borders and shadow

      TOOL = {
        name: 'record_swatches',
        description: 'Name every numbered finish sample on the sheet.',
        input_schema: {
          type: 'object',
          properties: {
            swatches: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  id: { type: 'integer', description: 'The red number on the sample.' },
                  set: { type: 'string', description: 'The heading the sample sits under, e.g. "Shaker Style Cabinets", "Vinyl Flooring", "Shutters".' },
                  name: { type: 'string', description: 'The sample\'s own caption, first line only, e.g. "Timberwolf", "9656 - Natural", "Catch Ice 4 x 10". Title case.' },
                  note: { type: 'string', description: 'Further caption lines, e.g. "Available in Upgrade Hardwood". Empty if none.' }
                },
                required: %w[id set name]
              }
            },
            skip: { type: 'array', items: { type: 'integer' }, description: 'Numbers on things that are not finish samples (logos, photos of homes, decoration).' },
            missed: {
              type: 'array',
              description: 'Samples on the sheet that carry no red number.',
              items: { type: 'object', properties: { set: { type: 'string' }, name: { type: 'string' } }, required: %w[set name] }
            }
          },
          required: ['swatches']
        }
      }.freeze

      # => { swatches: [{ set:, name:, note:, page:, image:, hex: }], missed: [{ set:, name: }], cost_usd: }
      def initialize(bytes, filename:, client: Catalog::PriceBooks::ClaudeClient)
        @bytes = bytes
        @filename = filename
        @client = client
      end

      def call
        cost = 0.0
        missed = []
        swatches = pages.each_with_index.flat_map do |page, index|
          small = page.resize(FIND_PX.to_f / page.width)
          boxes = find_boxes(small)
          next [] if boxes.empty?

          result = @client.call(system: system_prompt, tool: TOOL, max_tokens: 8000, temperature: 0, content: [
            { type: 'image', source: { type: 'base64', media_type: 'image/png', data: Base64.strict_encode64(numbered(small, boxes).pngsave_buffer) } },
            { type: 'text', text: "#{boxes.size} samples are outlined in red and numbered 1 to #{boxes.size}. Name each one." }
          ])
          cost += Catalog::PriceBooks::ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens])
          missed.concat(Array(result[:input]['missed']).map { |m| { set: m['set'].to_s.strip, name: m['name'].to_s.strip } })
          skip = Array(result[:input]['skip']).map(&:to_i)
          scale = page.width.to_f / small.width
          Array(result[:input]['swatches']).filter_map do |s|
            box = boxes[s['id'].to_i - 1]
            next if box.nil? || skip.include?(s['id'].to_i) || s['name'].to_s.strip.empty?

            cut(page, box, scale, s, index + 1)
          end
        end
        { swatches: swatches.uniq { |s| [s[:set].downcase, s[:name].downcase] }, missed: missed, cost_usd: cost.round(4) }
      end

      # Blocks of ink big enough to be a sample: solid ones, and white
      # samples that show only as a drawn outline. [x, y, w, h] at FIND_PX.
      def find_boxes(small)
        w = small.width
        h = small.height
        ink = (small < INK).bandor.ifthenelse(1, 0).cast(:uchar).write_to_memory.bytes
        seen = Array.new(w * h, false)
        boxes = []
        ink.each_index do |i|
          next if seen[i] || ink[i].zero?

          seen[i] = true
          stack = [i]
          x0 = x1 = i % w
          y0 = y1 = i / w
          count = 0
          until stack.empty?
            j = stack.pop
            count += 1
            jx = j % w
            jy = j / w
            x0 = jx if jx < x0
            x1 = jx if jx > x1
            y0 = jy if jy < y0
            y1 = jy if jy > y1
            [(j - 1 if jx.positive?), (j + 1 if jx < w - 1), (j - w if jy.positive?), (j + w if jy < h - 1)].each do |k|
              next if k.nil? || seen[k] || ink[k].zero?

              seen[k] = true
              stack << k
            end
          end
          bw = x1 - x0 + 1
          bh = y1 - y0 + 1
          next if bw < MIN_SIDE || bh < MIN_SIDE
          next unless count >= bw * bh * 0.6 || outline?(ink, w, x0, y0, x1, y1)

          boxes << [x0, y0, bw, bh]
        end
        boxes.sort_by { |x, y, _, _| [y / 20, x] }
      end

      private

      # A white sample drawn as a thin frame: ink along nearly all its edges.
      def outline?(ink, w, x0, y0, x1, y1)
        edge = (x0..x1).flat_map { |x| [y0 * w + x, y1 * w + x] } + (y0..y1).flat_map { |y| [y * w + x0, y * w + x1] }
        edge.count { |i| ink[i] == 1 } >= edge.size * 0.85
      end

      def numbered(small, boxes)
        out = small.copy
        boxes.each_with_index do |(x, y, bw, bh), i|
          out = out.draw_rect([220, 0, 0], x, y, bw, bh).draw_rect([220, 0, 0], x + 1, y + 1, bw - 2, bh - 2)
          out = label(out, (i + 1).to_s, x + 3, y + 3)
        end
        out
      end

      # A red number on a white tag in the box's corner.
      def label(image, text, x, y)
        glyph = Vips::Image.text(text, dpi: 110, font: 'sans bold')
        w = [glyph.width + 6, image.width - x].min
        h = [glyph.height + 4, image.height - y].min
        tag = (image.crop(x, y, w, h) * 0 + 255).cast(:uchar)
        ink = glyph.embed(3, 2, w, h)
        image.insert(ink.ifthenelse([220, 0, 0], tag, blend: true), x, y)
      end

      def system_prompt
        'You read decor selection sheets from manufactured home factories. Each sheet shows finish samples ' \
          '(countertops, cabinets, flooring, tile, wall boards, paint, siding, shingles, shutters and so on) as ' \
          'pictures under section headings, each with a caption. Each picture found on this sheet is outlined in red ' \
          'with a red number in its top left corner. Give each number the caption printed with that picture and ' \
          'the heading it sits under. A caption normally sits directly below its picture. Read the caption ' \
          'directly under each numbered box; never give a number the caption of a neighbouring picture. A sample ' \
          'with no red box goes under missed, not onto another number.'
      end

      def cut(page, box, scale, s, page_number)
        x, y, bw, bh = box.map { |v| v * scale }
        left = (x + bw * INSET).round.clamp(0, page.width - 2)
        top = (y + bh * INSET).round.clamp(0, page.height - 2)
        width = (bw * (1 - 2 * INSET)).round.clamp(2, page.width - left)
        height = (bh * (1 - 2 * INSET)).round.clamp(2, page.height - top)
        image = page.crop(left, top, width, height)
        { set: s['set'].to_s.strip, name: s['name'].to_s.strip, note: s['note'].to_s.strip.presence, page: page_number,
          image: image, hex: hex(image) }
      end

      def hex(image)
        '#' + (0..2).map { |b| image.extract_band(b).avg.round.clamp(0, 255).to_s(16).rjust(2, '0') }.join
      end

      def pages
        if @filename.to_s.downcase.end_with?('.pdf')
          Dir.mktmpdir do |dir|
            src = File.join(dir, 'sheet.pdf')
            File.binwrite(src, @bytes)
            _out, err, status = Open3.capture3('pdftoppm', '-r', CUT_DPI.to_s, '-png', '-l', '4', src, File.join(dir, 'page'))
            raise Error, "Could not read the PDF: #{err.to_s.first(200)}" unless status.success?

            Dir[File.join(dir, 'page*.png')].sort.map { |f| rgb(Vips::Image.new_from_buffer(File.binread(f), '')) }
          end
        else
          [rgb(Vips::Image.new_from_buffer(@bytes, ''))]
        end
      rescue Vips::Error => e
        raise Error, "Could not read the image: #{e.message.first(200)}"
      end

      def rgb(image)
        image = image.colourspace(:srgb) unless image.interpretation == :srgb
        image = image.flatten(background: [255, 255, 255]) if image.has_alpha?
        image.bands > 3 ? image.extract_band(0, n: 3) : image
      end
    end
  end
end
