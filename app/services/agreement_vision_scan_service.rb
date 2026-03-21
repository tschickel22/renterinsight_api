# frozen_string_literal: true

# AgreementVisionScanService - Hybrid PDF structure extraction + Claude AI
#
# Pipeline:
#   1. Extract text positions from PDF (PositionReceiver)
#   2. Extract blank lines, boxes, rectangles from PDF drawing ops (GraphicsReceiver)
#   3. Fix coordinates using CropBox (not MediaBox) for proper page dimensions
#   4. Send PDF + structured position data + detected blanks to Claude
#   5. Claude classifies fields semantically — geometry is pre-solved
#   6. Normalize with confidence scoring and stable field keys
#
class AgreementVisionScanService
  class ScanError < StandardError; end

  CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
  CLAUDE_MODEL = "claude-sonnet-4-20250514"
  MAX_PAGES = 16
  PDF_MAX_SIZE = 25_000_000

  # Calibration offsets (pdf-reader coords vs PDF.js browser rendering)
  # These compensate for a systematic rendering difference, NOT a coordinate space issue
  Y_OFFSET = -2.0          # Fields render ~2% too low in browser vs PDF coords
  CHECKBOX_X_OFFSET = -1.5  # Checkboxes render ~1.5% too far right

  # Minimum line width (as % of page) to be considered a blank input line
  MIN_LINE_WIDTH_PCT = 3.0
  # Maximum vertical gap (as % of page) between a label and a blank line to associate them
  MAX_LABEL_LINE_GAP_PCT = 3.0

  def initialize(api_key)
    @api_key = api_key
  end

  def scan(pdf_url, max_pages: MAX_PAGES)
    raise ScanError, "No PDF URL provided" if pdf_url.blank?

    Rails.logger.info "[VisionScan] Starting enhanced scan of: #{pdf_url}"

    pdf_data = download_pdf(pdf_url)
    Rails.logger.info "[VisionScan] PDF downloaded: #{pdf_data.bytesize} bytes"

    if pdf_data.bytesize > PDF_MAX_SIZE
      raise ScanError, "PDF is too large (#{(pdf_data.bytesize / 1_000_000.0).round(1)}MB). Maximum is 25MB."
    end

    # Step 1: Extract text positions + page dimensions (using CropBox)
    text_map, page_dimensions = extract_text_with_positions(pdf_data)
    total_pages = page_dimensions.keys.max || 1
    pages_to_scan = [max_pages, total_pages].min
    total_items = text_map.values.sum { |items| items.length }
    Rails.logger.info "[VisionScan] Extracted #{total_items} text items across #{total_pages} pages"

    # Step 2: Extract blank lines and boxes from PDF drawing operations
    blank_lines = extract_blank_lines(pdf_data, page_dimensions)
    total_blanks = blank_lines.values.sum { |items| items.length }
    Rails.logger.info "[VisionScan] Detected #{total_blanks} blank lines/boxes across #{blank_lines.keys.length} pages"

    # Step 3: Send PDF + text positions + detected blanks to Claude
    pdf_base64 = Base64.strict_encode64(pdf_data)
    fields = call_claude_with_positions(pdf_base64, text_map, blank_lines, pages_to_scan)
    Rails.logger.info "[VisionScan] Detected #{fields.length} fields"

    # Step 4: Post-placement validation — fix overlaps with printed text, snap to blanks
    fields = validate_placements(fields, text_map, blank_lines)
    Rails.logger.info "[VisionScan] Validated #{fields.length} fields"

    page_classifications = classify_pages(fields, total_pages)
    Rails.logger.info "[VisionScan] Classified #{page_classifications.length} pages"

    {
      fields: fields,
      pages_scanned: pages_to_scan,
      total_pages: total_pages,
      page_classifications: page_classifications,
    }
  end

  # Smart Scan: Compare empty template PDF against a filled example PDF
  def smart_scan(empty_pdf_url, filled_pdf_url, max_pages: MAX_PAGES)
    raise ScanError, "No empty PDF URL provided" if empty_pdf_url.blank?
    raise ScanError, "No filled PDF URL provided" if filled_pdf_url.blank?

    Rails.logger.info "[SmartScan] Starting comparison scan"

    empty_data = download_pdf(empty_pdf_url)
    filled_data = download_pdf(filled_pdf_url)

    [empty_data, filled_data].each_with_index do |data, i|
      label = i == 0 ? 'Empty' : 'Filled'
      if data.bytesize > PDF_MAX_SIZE
        raise ScanError, "#{label} PDF is too large (#{(data.bytesize / 1_000_000.0).round(1)}MB). Maximum is 25MB."
      end
    end

    empty_text_map, _ = extract_text_with_positions(empty_data)
    filled_text_map, _ = extract_text_with_positions(filled_data)
    total_pages = [empty_text_map.keys.max || 1, filled_text_map.keys.max || 1].max
    pages_to_scan = [max_pages, total_pages].min

    empty_b64 = Base64.strict_encode64(empty_data)
    filled_b64 = Base64.strict_encode64(filled_data)

    fields = call_claude_smart_scan(empty_b64, filled_b64, empty_text_map, filled_text_map, pages_to_scan)
    Rails.logger.info "[SmartScan] Detected #{fields.length} fields with example values"

    page_classifications = classify_pages(fields, total_pages)

    # Detect repeated fields
    value_pages = {}
    fields.each do |f|
      val = f[:example_value].to_s.strip.downcase
      next if val.blank? || val.length < 2
      value_pages[val] ||= []
      value_pages[val] << f[:page]
    end
    repeated_values = value_pages.select { |_, pages| pages.uniq.length > 1 }.keys.to_set
    fields.each do |f|
      val = f[:example_value].to_s.strip.downcase
      f[:is_repeated] = repeated_values.include?(val)
    end

    {
      fields: fields,
      pages_scanned: pages_to_scan,
      total_pages: total_pages,
      page_classifications: page_classifications,
      scan_type: 'smart',
    }
  end

  # V2 scan disabled — falls back to V1
  def scan_v2(pdf_url, max_pages: MAX_PAGES)
    scan(pdf_url, max_pages: max_pages)
  end

  private

  # ─── PDF Text Extraction (with CropBox fix) ───────────────────────────────────

  def extract_text_with_positions(pdf_data)
    text_map = {}
    page_dimensions = {}

    begin
      reader = PDF::Reader.new(StringIO.new(pdf_data))

      reader.pages.each_with_index do |page, idx|
        page_num = idx + 1

        # Use CropBox if available (visible area), otherwise MediaBox (full page)
        # This is critical — MediaBox can include non-visible margins
        crop_box = page.attributes[:CropBox] || page.attributes[:MediaBox]
        media_box = page.attributes[:MediaBox]

        if crop_box.is_a?(Array) && crop_box.length == 4
          origin_x = crop_box[0].to_f
          origin_y = crop_box[1].to_f
          page_w = (crop_box[2].to_f - origin_x).abs
          page_h = (crop_box[3].to_f - origin_y).abs
        else
          origin_x = 0.0
          origin_y = 0.0
          page_w = page.width.to_f
          page_h = page.height.to_f
        end

        next if page_w == 0 || page_h == 0

        page_dimensions[page_num] = {
          width: page_w, height: page_h,
          origin_x: origin_x, origin_y: origin_y,
          has_crop_box: page.attributes[:CropBox].present?
        }

        items = []
        receiver = PositionReceiver.new
        page.walk(receiver)

        receiver.runs.each do |run|
          next if run[:text].nil? || run[:text].strip.empty?
          # Convert from PDF coords (origin at bottom-left of CropBox) to percentages (origin top-left)
          x_pct = ((run[:x] - origin_x) / page_w * 100).round(1)
          y_pct = (100 - ((run[:y] - origin_y) / page_h * 100)).round(1)
          # Clamp to valid range
          x_pct = [[x_pct, 0].max, 100].min
          y_pct = [[y_pct, 0].max, 100].min
          items << { text: run[:text].strip, x: x_pct, y: y_pct, font_size: run[:font_size] }
        end

        text_map[page_num] = items if items.any?
      end
    rescue => e
      Rails.logger.warn "[VisionScan] pdf-reader text extraction failed: #{e.message}"
    end

    [text_map, page_dimensions]
  end

  # ─── PDF Blank Line / Box Detection (GraphicsReceiver) ─────────────────────────

  def extract_blank_lines(pdf_data, page_dimensions)
    blank_map = {}

    begin
      reader = PDF::Reader.new(StringIO.new(pdf_data))

      reader.pages.each_with_index do |page, idx|
        page_num = idx + 1
        dims = page_dimensions[page_num]
        next unless dims

        receiver = GraphicsReceiver.new
        page.walk(receiver)

        blanks = []

        # Process horizontal lines
        receiver.lines.each do |line|
          # Only keep horizontal lines (y1 ~= y2)
          next unless (line[:y1] - line[:y2]).abs < 2.0

          x1_pct = ((line[:x1] - dims[:origin_x]) / dims[:width] * 100).round(1)
          x2_pct = ((line[:x2] - dims[:origin_x]) / dims[:width] * 100).round(1)
          y_pct = (100 - ((line[:y1] - dims[:origin_y]) / dims[:height] * 100)).round(1)

          width_pct = (x2_pct - x1_pct).abs
          next if width_pct < MIN_LINE_WIDTH_PCT  # Skip tiny lines

          x_start = [x1_pct, x2_pct].min
          x_start = [[x_start, 0].max, 100].min
          y_pct = [[y_pct, 0].max, 100].min

          blanks << {
            type: 'line',
            x: x_start.round(1),
            y: y_pct.round(1),
            width: width_pct.round(1),
            height: 0.3  # Lines are thin
          }
        end

        # Process rectangles (form boxes)
        receiver.rectangles.each do |rect|
          x_pct = ((rect[:x] - dims[:origin_x]) / dims[:width] * 100).round(1)
          y_pct_bottom = ((rect[:y] - dims[:origin_y]) / dims[:height] * 100)
          rect_h_pct = (rect[:h] / dims[:height] * 100)
          y_pct = (100 - y_pct_bottom - rect_h_pct).round(1)  # Convert to top-left origin
          w_pct = (rect[:w] / dims[:width] * 100).round(1)
          h_pct = rect_h_pct.round(1)

          # Filter: must be at least 3% wide and less than 10% tall (not a border/frame)
          next if w_pct < MIN_LINE_WIDTH_PCT
          next if h_pct > 10  # Too tall = page border or section box
          next if h_pct < 0.2 # Too thin = decorative line

          x_pct = [[x_pct, 0].max, 100].min
          y_pct = [[y_pct, 0].max, 100].min

          blanks << {
            type: 'box',
            x: x_pct.round(1),
            y: y_pct.round(1),
            width: w_pct.round(1),
            height: h_pct.round(1)
          }
        end

        blank_map[page_num] = blanks if blanks.any?
      end
    rescue => e
      Rails.logger.warn "[VisionScan] Graphics extraction failed: #{e.message}"
    end

    blank_map
  end

  # ─── PDF Receivers ─────────────────────────────────────────────────────────────

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

  class GraphicsReceiver
    attr_reader :lines, :rectangles

    def initialize
      @lines = []
      @rectangles = []
      @path_points = []  # Current path being built
      @ctm = [1, 0, 0, 1, 0, 0]  # Current transformation matrix (identity)
    end

    # Path construction
    def move_to(x, y)
      tx, ty = transform(x, y)
      @path_points = [{ x: tx, y: ty }]
    end

    def line_to(x, y)
      tx, ty = transform(x, y)
      @path_points << { x: tx, y: ty }
    end

    def rectangle(x, y, w, h)
      tx, ty = transform(x, y)
      tw = w * @ctm[0]  # Scale width by CTM
      th = h * @ctm[3]  # Scale height by CTM
      @rectangles << { x: tx, y: ty, w: tw.abs, h: th.abs }
    end

    # Path painting — capture when path is stroked (drawn)
    def stroke
      capture_lines_from_path
      @path_points = []
    end

    def close_and_stroke
      stroke
    end

    def fill
      # Filled paths could be form boxes too
      capture_lines_from_path
      @path_points = []
    end

    def fill_and_stroke
      capture_lines_from_path
      @path_points = []
    end

    # Transformation matrix
    def concatenate_matrix(a, b, c, d, e, f)
      @ctm = [a, b, c, d, e, f]
    end

    def save_graphics_state
      @saved_ctm = @ctm.dup
    end

    def restore_graphics_state
      @ctm = @saved_ctm || [1, 0, 0, 1, 0, 0]
    end

    # Catch-all for unhandled callbacks
    def respond_to_missing?(*, **) = true
    def method_missing(*) = nil

    private

    def transform(x, y)
      # Apply current transformation matrix
      tx = @ctm[0] * x + @ctm[2] * y + @ctm[4]
      ty = @ctm[1] * x + @ctm[3] * y + @ctm[5]
      [tx, ty]
    end

    def capture_lines_from_path
      return if @path_points.length < 2

      # Extract line segments from path
      @path_points.each_cons(2) do |p1, p2|
        @lines << { x1: p1[:x], y1: p1[:y], x2: p2[:x], y2: p2[:y] }
      end
    end
  end

  # ─── Claude API Call (Enhanced with blank lines) ───────────────────────────────

  def call_claude_with_positions(pdf_base64, text_map, blank_lines, pages_to_scan)
    position_ref = build_position_reference(text_map, pages_to_scan)
    blanks_ref = build_blanks_reference(blank_lines, pages_to_scan)

    prompt = <<~PROMPT
      I need you to identify all FILLABLE FORM FIELDS in this PDF document — blank lines, empty input areas, checkboxes, and signature lines that a user needs to fill in.

      I have extracted two types of data from the PDF:
      1. TEXT POSITIONS — where labels and text are located
      2. DETECTED BLANK LINES AND BOXES — actual underlines and input boxes found in the PDF structure

      Both use coordinates as percentages of page dimensions (x=0 left edge, y=0 top edge).

      TEXT POSITIONS:
      #{position_ref}

      #{blanks_ref.present? ? "DETECTED BLANK LINES AND BOXES (these are REAL input areas detected from PDF drawing operations):\n#{blanks_ref}" : "No blank lines/boxes were detected from PDF structure."}

      YOUR TASK: For each fillable field, tell me:
      1. The field label and type
      2. WHERE THE INPUT AREA IS — use the DETECTED BLANK LINES above when available, otherwise estimate from text positions

      FIELD PLACEMENT RULES:
      - If a DETECTED BLANK LINE or BOX exists near a label, USE ITS COORDINATES for the field position. These are more accurate than estimates.
      - For "Label: ________" patterns: the INPUT starts AFTER the label text. The field x must be to the RIGHT of the label's last character.
      - For table rows: the INPUT is in the value column, to the right of the label.
      - For checkboxes "☐ text": the checkbox is at the same x,y as the text or slightly left. Width/height about 2.5.
      - For signature lines "SIGNED X ________": the input starts after "X".
      - For INITIALS "x____ x____": TWO separate fields side by side. Width ~6, height ~3.
      - For company rep/manager signatures: use type "signature" with group "signatures".
      - NEVER stack multiple fields at the same x,y.

      CRITICAL OVERLAP RULE — FIELDS MUST NEVER COVER TEXT:
      - A field box must ONLY cover blank/empty space — the underline, the blank cell, or the empty area.
      - A field box must NEVER overlap or cover printed label text, headings, or other static content.
      - For labeled blank lines like "Street Address" or "City" printed BELOW a line:
        The input field goes ON the blank line ABOVE the label. Set the field y so it sits on the line, NOT on top of the label text below.
      - For "Label: ______" on the same line: the field starts AFTER the colon/label, covering only the blank area.
      - For table cells: the field covers only the empty cell, not the row label in the left column.
      - Height must be minimal: use 2.5 for text/date/number, 2.2 for table cells, 2.5 for checkboxes, 4 for signatures. NEVER exceed 3.0 for text fields.

      For each field provide:
      - key: unique snake_case (e.g. "buyer_name")
      - label: exact label text
      - type: text|currency|number|percentage|date|checkbox|signature|initials
      - group: buyer|unit|pricing|delivery|signatures|general|terms
      - page: 1-indexed page number
      - x: INPUT AREA x position (percentage, 0-100) — must be on blank space, not on label text
      - y: INPUT AREA y position (percentage, 0-100) — must be on blank space, not on label text
      - width: field width as percentage (text: 15-30, checkbox: 2.5, signature: 25-35, currency: 10-15)
      - height: field height as percentage (text/date/number: 2.5, table cells: 2.2, checkbox: 2.5, signature: 4)
      - required: true/false
      - confidence: 0.0-1.0 (how confident you are in the placement. 1.0 = matched a detected blank line exactly, 0.5 = estimated from text position, 0.3 = guessed)

      CRITICAL: Output ONLY a JSON array. No explanation. Start with [ end with ].

      [
        {"key":"date","label":"Date","type":"date","group":"general","page":1,"x":84,"y":15,"width":14,"height":2.5,"required":true,"confidence":0.9},
        {"key":"buyer_name","label":"Buyer","type":"text","group":"buyer","page":1,"x":42,"y":22,"width":35,"height":2.5,"required":true,"confidence":0.7}
      ]
    PROMPT

    body = {
      model: CLAUDE_MODEL,
      max_tokens: 64000,
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
    http.read_timeout = 180
    http.open_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = @api_key
    request["anthropic-version"] = "2023-06-01"
    request.body = body.to_json

    Rails.logger.info "[VisionScan] Sending PDF + #{text_map.values.sum(&:length)} text items + #{blank_lines.values.sum(&:length)} blank lines to Claude"

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

  def build_blanks_reference(blank_lines, max_pages)
    lines = []
    blank_lines.each do |page_num, blanks|
      next if page_num > max_pages
      next if blanks.empty?
      lines << "=== PAGE #{page_num} BLANKS ==="
      sorted = blanks.sort_by { |b| [b[:y], b[:x]] }
      sorted.each do |blank|
        if blank[:type] == 'line'
          lines << "  [LINE x:#{blank[:x]}, y:#{blank[:y]}, width:#{blank[:width]}] — horizontal underline"
        else
          lines << "  [BOX x:#{blank[:x]}, y:#{blank[:y]}, width:#{blank[:width]}, height:#{blank[:height]}] — input box"
        end
      end
    end
    lines.join("\n")
  end

  # ─── Smart Scan (unchanged prompt, uses same structure) ────────────────────────

  def call_claude_smart_scan(empty_b64, filled_b64, empty_text_map, filled_text_map, pages_to_scan)
    empty_ref = build_position_reference(empty_text_map, pages_to_scan)
    filled_ref = build_position_reference(filled_text_map, pages_to_scan)

    prompt = <<~PROMPT
      I have TWO versions of the same PDF form:
      1. DOCUMENT 1 (first PDF): The EMPTY/blank template
      2. DOCUMENT 2 (second PDF): A COMPLETED version with real data filled in

      I have extracted text positions from both. Coordinates are percentages (x=0 left edge, y=0 top edge).

      EMPTY TEMPLATE TEXT POSITIONS:
      #{empty_ref}

      FILLED DOCUMENT TEXT POSITIONS:
      #{filled_ref}

      YOUR TASK: Compare the two documents to identify every fillable field. For each field:
      1. Find the field label and input area position (from the EMPTY template)
      2. Find the actual value written in that field (from the FILLED document)
      3. Infer the data type from the actual value
      4. Detect if the field appears to be calculated from other fields

      TYPE INFERENCE RULES:
      - Values like "$177,166.00" or "5,314.98" -> currency
      - Values like "02/25/2026" or "12/15/2025" -> date
      - Values like "3" or "68" (small integers in dimension/count context) -> number
      - Checked boxes (filled checkbox, X mark, checkmark) -> checkbox
      - Signature lines with names -> signature
      - Everything else -> text

      FORMULA DETECTION:
      - If SUB-TOTAL = BASE PRICE + OPTIONAL EQUIPMENT, output formula accordingly
      - Only include formula if you are confident the math checks out

      POSITIONING RULES:
      - For "Label: ________" patterns: INPUT starts AFTER the label text
      - For table cells: INPUT is in the value column, not the label column
      - Checkboxes: width/height about 2.5
      - For INITIALS "x____ x____": TWO separate fields. Width ~6, height ~3.
      - For company rep/manager signatures: type "signature", group "signatures"
      - NEVER stack multiple fields at the same x,y

      For each field provide:
      - key: unique snake_case (e.g. "buyer_name")
      - label: exact label text from empty form
      - type: text|currency|number|percentage|date|checkbox|signature|initials (INFERRED from filled value)
      - group: buyer|unit|pricing|delivery|insulation|optional_equipment|remarks|trade_in|shipping|signatures|terms|general
      - page: 1-indexed page number
      - x: INPUT AREA x position (percentage, 0-100) from EMPTY template
      - y: INPUT AREA y position (percentage, 0-100) from EMPTY template
      - width: field width as percentage
      - height: field height as percentage
      - required: true/false
      - example_value: the actual value from the FILLED document (string, or null if blank)
      - inferred_type: the type you inferred from the example value
      - formula: calculation formula if detected, or null
      - confidence: 0.0-1.0 (placement confidence)

      CRITICAL: Output ONLY a JSON array. No explanation. Start with [ end with ].
    PROMPT

    body = {
      model: CLAUDE_MODEL,
      max_tokens: 64000,
      messages: [
        {
          role: "user",
          content: [
            { type: "document", source: { type: "base64", media_type: "application/pdf", data: empty_b64 } },
            { type: "document", source: { type: "base64", media_type: "application/pdf", data: filled_b64 } },
            { type: "text", text: prompt },
          ],
        },
      ],
    }

    uri = URI(CLAUDE_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 180
    http.open_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = @api_key
    request["anthropic-version"] = "2023-06-01"
    request.body = body.to_json

    Rails.logger.info "[SmartScan] Sending 2 PDFs + position data to Claude"

    response = http.request(request)

    unless response.code == "200"
      error_body = JSON.parse(response.body) rescue {}
      error_msg = error_body.dig("error", "message") || "HTTP #{response.code}"
      Rails.logger.error "[SmartScan] Claude API error: #{error_msg}"
      raise ScanError, "Smart scan failed: #{error_msg}"
    end

    result = JSON.parse(response.body)
    text_content = result["content"]&.find { |c| c["type"] == "text" }&.fetch("text", "")

    parse_smart_response(text_content)
  end

  # ─── Response Parsing ─────────────────────────────────────────────────────────

  def parse_smart_response(text)
    fields = parse_response(text)
    raw_fields = extract_raw_json_fields(text)

    fields.each_with_index do |field, idx|
      raw = raw_fields[idx] if raw_fields
      if raw
        field[:example_value] = raw["example_value"]
        field[:inferred_type] = raw["inferred_type"].to_s.presence
        field[:formula] = raw["formula"].to_s.presence
      else
        field[:example_value] = nil
        field[:inferred_type] = nil
        field[:formula] = nil
      end
      field[:is_repeated] = false
    end

    fields
  end

  def extract_raw_json_fields(text)
    json_str = text.strip
    json_str = json_str.gsub(/```json?\s*/i, '').gsub(/```/, '').strip if json_str.include?('```')
    json_str = $1 if !json_str.start_with?('[') && json_str =~ /(\[\s*\{.*\}\s*\])/m
    return nil unless json_str.start_with?('[')
    JSON.parse(json_str) rescue nil
  end

  def parse_response(text)
    json_str = text.strip

    if json_str.include?('```')
      if json_str =~ /```(?:json)?\s*\n?(\[.*?\])\s*\n?```/m
        json_str = $1
      else
        json_str = json_str.gsub(/```json?\s*/i, '').gsub(/```/, '').strip
      end
    end

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
    # Stable deterministic key: use label + page + approximate position
    raw_key = field["key"].to_s.strip.presence
    label = field["label"].to_s.strip.presence || "Field #{idx + 1}"
    page = [(field["page"] || 1).to_i, 1].max

    if raw_key.present?
      key = raw_key
    else
      key = label.parameterize(separator: '_').first(30)
    end
    key = "cf_#{key}" unless key.start_with?("cf_")

    type = field["type"].to_s.strip.downcase
    type = "text" unless %w[text currency number percentage date select checkbox signature initials].include?(type)

    group = field["group"].to_s.strip.downcase
    group = "general" unless %w[buyer delivery unit insulation pricing optional_equipment remarks trade_in shipping signatures terms general].include?(group)

    # Apply calibration offsets (compensates for pdf-reader vs PDF.js rendering gap)
    raw_y = field["y"].to_f + Y_OFFSET
    raw_x = field["x"].to_f
    raw_x += CHECKBOX_X_OFFSET if type == 'checkbox'

    # Confidence from Claude (0.0-1.0), default 0.5 if not provided
    confidence = field["confidence"].to_f
    confidence = 0.5 if confidence <= 0 || confidence > 1.0

    {
      key: key,
      label: label,
      type: type,
      group: group,
      page: page,
      x: [[raw_x, 1].max, 95].min.round(1),
      y: [[raw_y, 1].max, 95].min.round(1),
      width: [[field["width"].to_f, 2].max, 50].min.round(1),
      height: clamp_height(type, field["height"].to_f),
      required: field["required"] == true,
      confidence: confidence.round(2),
    }
  end

  # ─── Post-Placement Validation (Conservative) ─────────────────────────────────

  # Light validation: only penalizes confidence for fields overlapping long body text.
  # Does NOT move fields — Claude's placement + blank-line data is more reliable than
  # generic push-away logic. Labels (short text) near fields are expected and allowed.
  def validate_placements(fields, text_map, blank_lines)
    body_text_zones = build_body_text_zones(text_map)
    adjustments = 0

    fields.map do |field|
      page = field[:page]
      page_body = body_text_zones[page] || []

      # Skip types that naturally overlap text
      next field if %w[signature initials checkbox].include?(field[:type])

      fx1 = field[:x]
      fy1 = field[:y]
      fx2 = fx1 + field[:width]
      fy2 = fy1 + field[:height]

      # Only check against BODY text (sentences/paragraphs), not short labels
      heavy_overlaps = page_body.select do |tz|
        rects_overlap?(fx1, fy1, fx2, fy2, tz[:x1], tz[:y1], tz[:x2], tz[:y2])
      end

      if heavy_overlaps.any?
        # Don't move the field — just reduce confidence so user reviews it
        field = field.dup
        field[:confidence] = [field[:confidence] * 0.6, 0.15].max.round(2)
        adjustments += 1
        Rails.logger.debug "[Validator] Flagged '#{field[:label]}' — overlaps body text (#{heavy_overlaps.length} zones)"
      end

      field
    end
  end

  # Build exclusion zones from BODY TEXT only (5+ words). Short labels are expected
  # near fields and should NOT trigger corrections.
  def build_body_text_zones(text_map)
    zones = {}
    text_map.each do |page_num, items|
      page_zones = items.filter_map do |item|
        text = item[:text].to_s.strip
        word_count = text.split(/\s+/).length
        next nil if word_count < 5  # Skip labels, headings, short text

        est_width = text.length * 0.5
        est_height = 1.6

        { x1: item[:x], y1: item[:y], x2: item[:x] + est_width, y2: item[:y] + est_height, text: text }
      end

      zones[page_num] = page_zones if page_zones.any?
    end
    zones
  end

  def rects_overlap?(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
    ax1 < bx2 && ax2 > bx1 && ay1 < by2 && ay2 > by1
  end

  # Type-specific height clamping to prevent oversized fields
  def clamp_height(type, raw_height)
    max_h = case type
            when 'signature' then 5.0
            when 'initials' then 3.5
            when 'checkbox' then 2.5
            else 3.0  # text, date, number, currency, percentage
            end
    min_h = type == 'checkbox' ? 2.0 : 1.5
    [[raw_height, min_h].max, max_h].min.round(1)
  end

  # ─── Page Classification ───────────────────────────────────────────────────────

  def classify_pages(fields, total_pages)
    page_data = {}
    fields.each do |f|
      p = f[:page] || 1
      page_data[p] ||= { signatures: 0, initials: 0, checkboxes: 0, data_fields: 0, labels: [] }
      case f[:type]
      when 'signature' then page_data[p][:signatures] += 1
      when 'initials' then page_data[p][:initials] += 1
      when 'checkbox'
        page_data[p][:checkboxes] += 1
        page_data[p][:data_fields] += 1
      else
        page_data[p][:data_fields] += 1
      end
      page_data[p][:labels] << f[:label]
    end

    (1..total_pages).map do |page_num|
      info = page_data[page_num] || { signatures: 0, initials: 0, checkboxes: 0, data_fields: 0, labels: [] }
      has_sigs = info[:signatures] > 0
      has_initials = info[:initials] > 0
      has_data = info[:data_fields] > 0

      page_type = if has_data && (has_sigs || has_initials)
                    'hybrid'
                  elsif has_data
                    'data_page'
                  elsif has_sigs || has_initials
                    'signature_page'
                  else
                    'signature_page'
                  end

      title = if info[:labels].any?
                first_label = info[:labels].first.to_s
                first_label.length > 40 ? first_label[0..37] + '...' : first_label
              else
                "Page #{page_num}"
              end

      {
        page: page_num,
        type: page_type,
        title: title,
        has_signatures: has_sigs,
        has_initials: has_initials,
        has_data_fields: has_data,
        field_count: (info[:signatures] + info[:initials] + info[:data_fields]),
      }
    end
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
