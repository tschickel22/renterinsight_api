# frozen_string_literal: true

# AgreementVisionScanService - Hybrid PDF text extraction + Claude AI
#
# Approach: Extract text positions from PDF, send to Claude along with the PDF,
# Claude uses the exact coordinates to place fields precisely.
# A small Y-offset calibration corrects for the consistent downward shift
# between PDF coordinate space and browser rendering.
#
class AgreementVisionScanService
  class ScanError < StandardError; end

  CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
  CLAUDE_MODEL = "claude-sonnet-4-20250514"
  MAX_PAGES = 16
  PDF_MAX_SIZE = 25_000_000

  # Calibration offsets (browser rendering vs PDF coords)
  Y_OFFSET = -2.0       # Fields render ~2% too low
  CHECKBOX_X_OFFSET = -1.5  # Checkboxes render ~1.5% too far right

  def initialize(api_key)
    @api_key = api_key
  end

  def scan(pdf_url, max_pages: MAX_PAGES)
    raise ScanError, "No PDF URL provided" if pdf_url.blank?

    Rails.logger.info "[VisionScan] Starting hybrid scan of: #{pdf_url}"

    pdf_data = download_pdf(pdf_url)
    Rails.logger.info "[VisionScan] PDF downloaded: #{pdf_data.bytesize} bytes"

    if pdf_data.bytesize > PDF_MAX_SIZE
      raise ScanError, "PDF is too large (#{(pdf_data.bytesize / 1_000_000.0).round(1)}MB). Maximum is 25MB."
    end

    # Step 1: Extract text with positions using pdf-reader
    text_map = extract_text_with_positions(pdf_data)
    total_pages = text_map.keys.max || 1
    pages_to_scan = [max_pages, total_pages].min
    total_items = text_map.values.sum { |items| items.length }
    Rails.logger.info "[VisionScan] Extracted #{total_items} text items across #{total_pages} pages"

    # Step 2: Send PDF + text position data to Claude
    pdf_base64 = Base64.strict_encode64(pdf_data)
    fields = call_claude_with_positions(pdf_base64, text_map, pages_to_scan)
    Rails.logger.info "[VisionScan] Detected #{fields.length} fields"

    {
      fields: fields,
      pages_scanned: pages_to_scan,
      total_pages: total_pages,
    }
  end

  private

  # ─── PDF Text Extraction ──────────────────────────────────────────────────────

  def extract_text_with_positions(pdf_data)
    text_map = {}

    begin
      reader = PDF::Reader.new(StringIO.new(pdf_data))

      reader.pages.each_with_index do |page, idx|
        page_num = idx + 1
        page_w = page.width.to_f
        page_h = page.height.to_f
        next if page_w == 0 || page_h == 0

        items = []
        receiver = PositionReceiver.new
        page.walk(receiver)

        receiver.runs.each do |run|
          next if run[:text].nil? || run[:text].strip.empty?
          x_pct = (run[:x] / page_w * 100).round(1)
          y_pct = (100 - (run[:y] / page_h * 100)).round(1) # PDF y is bottom-up
          items << { text: run[:text].strip, x: x_pct, y: y_pct }
        end

        text_map[page_num] = items if items.any?
      end
    rescue => e
      Rails.logger.warn "[VisionScan] pdf-reader failed: #{e.message}"
    end

    text_map
  end

  class PositionReceiver
    attr_reader :runs

    def initialize
      @runs = []
      @x = 0
      @y = 0
      @font_size = 12
    end

    def set_text_matrix_and_text_line_matrix(_a, _b, _c, d, e, f)
      @x = e
      @y = f
      @font_size = d.abs if d.abs > 0
    end

    def move_text_position(tx, ty)
      @x += tx
      @y += ty
    end

    def move_text_position_and_set_leading(tx, ty)
      move_text_position(tx, ty)
    end

    def show_text(string)
      return if string.nil?
      safe = string.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').strip
      return if safe.empty?
      @runs << { text: safe, x: @x, y: @y, font_size: @font_size }
    end

    def show_text_with_positioning(params)
      parts = params.select { |p| p.is_a?(String) }.map { |p| p.encode('UTF-8', invalid: :replace, undef: :replace, replace: '') }
      combined = parts.join('').strip
      return if combined.empty?
      @runs << { text: combined, x: @x, y: @y, font_size: @font_size }
    end

    def set_text_font_and_size(_, size)
      @font_size = size.abs if size
    end

    def respond_to_missing?(*, **) = true
    def method_missing(*) = nil
  end

  # ─── Claude API Call ──────────────────────────────────────────────────────────

  def call_claude_with_positions(pdf_base64, text_map, pages_to_scan)
    position_ref = build_position_reference(text_map, pages_to_scan)

    prompt = <<~PROMPT
      I need you to identify all FILLABLE FORM FIELDS in this PDF document — blank lines, empty input areas, checkboxes, and signature lines that a user needs to fill in.

      I have extracted the exact text positions from the PDF. Each text item shows its coordinates as percentages of page width (x) and height (y), where x=0 is the left edge and y=0 is the top edge.

      TEXT POSITIONS:
      #{position_ref}

      YOUR TASK: For each fillable field you find in the document, tell me:
      1. The field label and type
      2. WHERE THE INPUT AREA IS (not the label) — use the text positions above to calculate exact coordinates

      POSITIONING RULES — THIS IS CRITICAL:
      - For "Label: ________" patterns: the INPUT starts AFTER the label text. If the label "Date:" is at x:78, y:15, the input area starts at roughly x:84 (after "Date:" width) at the same y.
      - For table rows like "Manufacturer | [blank cell]": the INPUT is in the blank cell to the right of the label. If "Manufacturer" is at x:28 and the table's value column starts at x:42, the input is at x:42.
      - For checkboxes "☐ Joint Tenants": the checkbox is at the SAME x,y as the text or slightly left of it. Width and height should be about 2.5.
      - For signature lines "SIGNED X ________": the input starts after "X" and spans to the right.
      - For stacked table fields (Manufacturer, Model, Serial No. etc.): each field should be at the SAME x position but DIFFERENT y positions, matching the rows in the table.
      - NEVER stack multiple fields at the same x,y — each field must have a UNIQUE y position.

      For each field provide:
      - key: unique snake_case (e.g. "buyer_name")
      - label: exact label text
      - type: text|currency|number|percentage|date|checkbox|signature
      - group: buyer|unit|pricing|delivery|signatures|general|terms
      - page: 1-indexed page number
      - x: INPUT AREA x position (percentage, 0-100)
      - y: INPUT AREA y position (percentage, 0-100)
      - width: field width as percentage (text: 15-30, checkbox: 2.5, signature: 25-35, currency: 10-15)
      - height: field height as percentage (most: 2.5-3, checkbox: 2.5, signature: 4-5)
      - required: true/false

      CRITICAL: Output ONLY a JSON array. No explanation. Start with [ end with ].

      [
        {"key":"date","label":"Date","type":"date","group":"general","page":1,"x":84,"y":15,"width":14,"height":2.8,"required":true},
        {"key":"buyer_name","label":"Buyer","type":"text","group":"buyer","page":1,"x":42,"y":22,"width":35,"height":2.8,"required":true}
      ]
    PROMPT

    body = {
      model: CLAUDE_MODEL,
      max_tokens: 16000,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "document",
              source: { type: "base64", media_type: "application/pdf", data: pdf_base64 },
            },
            { type: "text", text: prompt },
          ],
        },
      ],
    }

    uri = URI(CLAUDE_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120
    http.open_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = @api_key
    request["anthropic-version"] = "2023-06-01"
    request.body = body.to_json

    Rails.logger.info "[VisionScan] Sending PDF + position data to Claude"

    response = http.request(request)

    unless response.code == "200"
      error_body = JSON.parse(response.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{response.code}"
      Rails.logger.error "[VisionScan] Claude API error: #{error_msg}"
      raise ScanError, "AI scan failed: #{error_msg}"
    end

    result = JSON.parse(response.body)
    text_content = result["content"]&.find { |c| c["type"] == "text" }&.fetch("text", "")

    parse_response(text_content)
  end

  def build_position_reference(text_map, max_pages)
    lines = []
    text_map.each do |page_num, items|
      next if page_num > max_pages
      lines << "=== PAGE #{page_num} ==="
      sorted = items.sort_by { |i| [i[:y], i[:x]] }
      sorted.each do |item|
        lines << "  [x:#{item[:x]}, y:#{item[:y]}] \"#{item[:text]}\""
      end
    end
    lines.join("\n")
  end

  # ─── Response Parsing ─────────────────────────────────────────────────────────

  def parse_response(text)
    json_str = text.strip

    # Handle markdown code fences with prose before/after
    if json_str.include?('```')
      if json_str =~ /```(?:json)?\s*\n?(\[.*?\])\s*\n?```/m
        json_str = $1
        Rails.logger.info "[VisionScan] Extracted JSON from markdown code fences"
      else
        json_str = json_str.gsub(/```json?\s*/i, '').gsub(/```/, '').strip
      end
    end

    # Handle prose instead of JSON
    if !json_str.start_with?('[') && !json_str.start_with?('{')
      lower = json_str.downcase
      if lower.include?('no fillable') || lower.include?('no form field') ||
         lower.include?('no fields') || lower.include?('no input')
        return []
      end
      if json_str =~ /(\[\s*\{.*\}\s*\])/m
        json_str = $1
      else
        raise ScanError, "No fillable form fields were detected in this document."
      end
    end

    return [] if json_str.strip == '[]'

    begin
      fields = JSON.parse(json_str)
    rescue JSON::ParserError
      # Fix truncated JSON
      if json_str.start_with?('[')
        last_brace = json_str.rindex('}')
        if last_brace
          begin
            fields = JSON.parse(json_str[0..last_brace] + ']')
            Rails.logger.warn "[VisionScan] Fixed truncated JSON (#{fields.length} fields)"
          rescue JSON::ParserError
            raise ScanError, "AI response was incomplete. Try scanning fewer pages."
          end
        else
          raise ScanError, "Failed to parse AI response."
        end
      else
        raise ScanError, "Failed to parse AI response."
      end
    end

    raise ScanError, "Unexpected AI response format" unless fields.is_a?(Array)

    normalized = fields.map.with_index { |f, i| normalize_field(f, i) }.compact
    deduplicate_positions(normalized)
  end

  def normalize_field(field, idx)
    key = field["key"].to_s.strip.presence || "field_#{idx + 1}"
    key = "cf_#{key}" unless key.start_with?("cf_")

    type = field["type"].to_s.strip.downcase
    type = "text" unless %w[text currency number percentage date select checkbox signature].include?(type)

    group = field["group"].to_s.strip.downcase
    group = "general" unless %w[buyer delivery unit insulation pricing optional_equipment remarks trade_in shipping signatures terms general].include?(group)

    # Apply calibration offsets
    raw_y = field["y"].to_f + Y_OFFSET
    raw_x = field["x"].to_f
    raw_x += CHECKBOX_X_OFFSET if type == 'checkbox'

    {
      key: key,
      label: field["label"].to_s.strip.presence || "Field #{idx + 1}",
      type: type,
      group: group,
      page: [(field["page"] || 1).to_i, 1].max,
      x: [[raw_x, 1].max, 95].min.round(1),
      y: [[raw_y, 1].max, 95].min.round(1),
      width: [[field["width"].to_f, 2].max, 50].min.round(1),
      height: [[field["height"].to_f, 1.5].max, 8].min.round(1),
      required: field["required"] == true,
    }
  end

  def deduplicate_positions(fields)
    seen = {}
    fields.map do |field|
      pos_key = "#{field[:page]}-#{field[:x].round(0)}-#{field[:y].round(0)}"
      if seen[pos_key]
        field[:y] = (field[:y] + 3.5).round(1)
        field[:y] = 95 if field[:y] > 95
      end
      seen[pos_key] = true
      field
    end
  end

  def download_pdf(url)
    uri = URI(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    raise ScanError, "Failed to download PDF: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    response.body
  end
end
