# frozen_string_literal: true

# AgreementVisionScanService - Hybrid PDF structure extraction + Claude AI
#
# Pipeline:
#   0. Check for native AcroForm fields — if found, use pixel-perfect PDF coordinates (PATH A)
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

  # Minimum AcroForm fields to use native extraction instead of vision pipeline
  ACROFORM_MIN_FIELDS = 5

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

    # Step 0: Check for native AcroForm fields (pixel-perfect, no Claude API cost)
    acroform_result = extract_acroform_fields(pdf_data)
    if acroform_result[:has_acroform] && acroform_result[:fields].length >= ACROFORM_MIN_FIELDS
      Rails.logger.info "[AcroForm] PATH A: Fillable PDF detected with #{acroform_result[:fields].length} native fields"
      return build_acroform_scan_result(acroform_result[:fields], max_pages, pdf_data)
    end

    Rails.logger.info "[VisionScan] PATH B: No AcroForm detected, using vision scan pipeline"

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

    # Step 4: Pattern Placement Engine — override Claude geometry with deterministic rules
    fields = apply_pattern_placements(fields, text_map, blank_lines)
    Rails.logger.info "[VisionScan] Pattern placement applied to #{fields.length} fields"

    # Step 5: Post-placement validation — fix overlaps with printed text, snap to blanks
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

  # ─── Pattern Placement Engine ─────────────────────────────────────────────────
  #
  # Claude identifies WHAT each field is (semantic classification).
  # For known layout patterns, PLACEMENT comes from deterministic rules using
  # actual PDF geometry. If no pattern matches, Claude's original placement is kept.

  def apply_pattern_placements(fields, text_map, blank_lines)
    fields_by_page = fields.group_by { |f| f[:page] }
    result = []

    fields_by_page.each do |page, page_fields|
      page_text = text_map[page] || []
      page_blanks = blank_lines[page] || []

      # Detect all patterns on this page (order matters for exclusion sets)
      # 1. Tables first
      table_cells = detect_table_rows(page_text, page_blanks)

      # 2. Address segments second (returns claimed blank indices)
      address_result = detect_address_segments(page_text, page_blanks)
      address_segs = address_result[:segments]
      address_claimed_blanks = address_result[:claimed_blank_indices]

      # 3. Checkboxes
      checkbox_sqrs = detect_checkbox_squares(page_blanks)

      # 4. Label-field pairs LAST, excluding address-claimed blanks
      label_pairs = detect_label_field_pairs(page_text, page_blanks, address_claimed_blanks)

      all_patterns = table_cells + address_segs + checkbox_sqrs + label_pairs

      if all_patterns.any?
        Rails.logger.debug "[PatternEngine] Page #{page}: #{table_cells.length} table cells, " \
          "#{label_pairs.length} label pairs, #{address_segs.length} address segs, " \
          "#{checkbox_sqrs.length} checkboxes"
      end

      page_fields.each do |field|
        matched = match_field_to_pattern(field, all_patterns)
        if matched
          field = field.dup
          field[:x] = matched[:field_x].round(1)
          field[:y] = matched[:field_y].round(1)
          field[:width] = matched[:field_width].round(1)
          # Deterministically-placed fields (address segments, etc.) have pre-computed
          # height that accounts for label avoidance — don't override with clamp_height
          if matched[:pattern_type].to_s == 'address_segment'
            field[:height] = matched[:field_height].round(1)
          else
            field[:height] = clamp_height(field[:type], matched[:field_height])
          end
          field[:confidence] = [matched[:confidence], field[:confidence]].max.round(2)
          field[:pattern_source] = matched[:pattern_type]
          Rails.logger.debug "[PatternEngine] Matched '#{field[:label]}' -> #{matched[:pattern_type]} " \
            "(x:#{field[:x]}, y:#{field[:y]}, w:#{field[:width]}, h:#{field[:height]})"
        end
        result << field
      end
    end

    result
  end

  # Match a Claude field to the best detected pattern by label proximity and position overlap.
  # Address segments use semantic SLOT matching (keyword-based), not geometric proximity.
  def match_field_to_pattern(field, patterns)
    return nil if patterns.empty?

    field_label = field[:label].to_s.downcase

    # Try address segment slot matching first (keyword-based, not distance-based)
    address_patterns = patterns.select { |p| p[:pattern_type].to_s == 'address_segment' }
    if address_patterns.any?
      address_slot = infer_address_slot(field_label)
      if address_slot
        slot_match = address_patterns.find { |p| p[:slot].to_s == address_slot }
        return slot_match if slot_match
      end
    end

    # Non-address patterns: use position proximity + label text matching
    non_address = patterns.reject { |p| p[:pattern_type].to_s == 'address_segment' }
    candidates = non_address.select do |p|
      (field[:y] - p[:field_y]).abs < 5.0 &&
        (field[:x] - p[:field_x]).abs < 15.0
    end

    return nil if candidates.empty?

    best = candidates.min_by do |p|
      label_match = if p[:label_text] && field[:label]
                      normalized_label = field[:label].to_s.downcase.gsub(/[^a-z0-9]/, '')
                      pattern_label = p[:label_text].to_s.downcase.gsub(/[^a-z0-9]/, '')
                      if normalized_label == pattern_label || normalized_label.include?(pattern_label) ||
                         pattern_label.include?(normalized_label)
                        0
                      else
                        100
                      end
                    else
                      50
                    end

      position_dist = Math.sqrt((field[:x] - p[:field_x])**2 + (field[:y] - p[:field_y])**2)
      label_match + position_dist
    end

    best
  end

  # Infer which address slot a Claude field label maps to
  ADDRESS_SLOT_KEYWORDS = {
    'street_address' => /\b(street|address)\b/,
    'city'           => /\bcity\b/,
    'state'          => /\bstate\b/,
    'zip'            => /\b(zip|postal)\b/,
  }.freeze

  def infer_address_slot(label_text)
    lower = label_text.to_s.downcase
    ADDRESS_SLOT_KEYWORDS.each do |slot, pattern|
      return slot if lower.match?(pattern)
    end
    nil
  end

  # ─── Pattern Detector: Table Rows ──────────────────────────────────────────────
  #
  # Find groups of text items forming table rows (e.g., Manufacturer/Model/Serial grid).
  # A table is 3+ rows with consistent left-edge alignment and similar structure.

  def detect_table_rows(page_text, page_blanks)
    return [] if page_text.empty?

    # Group text items by similar y-coordinate (within 1% = same row)
    rows = group_by_y(page_text, 1.0)
    return [] if rows.length < 3

    # For each row, identify label+blank pairs
    row_data = rows.filter_map do |y_center, items|
      # Find blank lines on the same y-band
      row_blanks = page_blanks.select { |b| (b[:y] - y_center).abs < 1.5 }

      # Sort items left-to-right
      sorted_items = items.sort_by { |i| i[:x] }

      cells = []
      sorted_items.each do |item|
        text = item[:text].to_s.strip
        next if text.empty?

        # Find a blank line to the right of this text
        est_label_right = item[:x] + (text.length * 0.55)
        matching_blank = row_blanks.find { |b| b[:x] >= est_label_right - 2.0 }

        if matching_blank
          cells << {
            label_text: text,
            label_x: item[:x],
            label_y: item[:y],
            field_x: matching_blank[:x],
            field_y: matching_blank[:y] - 0.3,
            field_width: matching_blank[:width],
            field_height: 2.2,
            confidence: 0.93,
            pattern_type: :table_row,
          }
        end
      end

      { y: y_center, cells: cells, left_edge: sorted_items.first[:x] } if cells.any?
    end

    return [] if row_data.length < 3

    # Check for consistent left-edge alignment (table indicator)
    left_edges = row_data.map { |r| r[:left_edge] }
    median_left = left_edges.sort[left_edges.length / 2]
    aligned_rows = row_data.select { |r| (r[:left_edge] - median_left).abs < 3.0 }

    return [] if aligned_rows.length < 3

    # Extract all cells from aligned rows
    aligned_rows.flat_map { |r| r[:cells] }
  end

  # ─── Pattern Detector: Label-Field Pairs ───────────────────────────────────────
  #
  # Find standalone "Label ________" patterns (label on left, fill line on right).

  def detect_label_field_pairs(page_text, page_blanks, excluded_blank_indices = Set.new)
    return [] if page_blanks.empty?

    pairs = []

    page_blanks.each_with_index do |blank, bl_idx|
      next if excluded_blank_indices.include?(bl_idx)

      # Find nearest text item to the LEFT on the same y-band (within 1.5% y tolerance)
      candidates = page_text.select do |item|
        (item[:y] - blank[:y]).abs < 1.5 &&
          item[:x] + (item[:text].to_s.length * 0.55) < blank[:x] + 2.0
      end

      label_item = candidates.max_by { |i| i[:x] }  # rightmost label to the left
      next unless label_item

      label_text = label_item[:text].to_s.strip
      next if label_text.empty?

      pairs << {
        label_text: label_text,
        label_x: label_item[:x],
        label_y: label_item[:y],
        field_x: blank[:x],
        field_y: blank[:y] - 0.5,
        field_width: blank[:width],
        field_height: 2.5,
        confidence: 0.92,
        pattern_type: :label_field_pair,
      }
    end

    pairs
  end

  # ─── Pattern Detector: Address Segments (Strict) ────────────────────────────────
  #
  # Detects segmented address rows where blank segments sit ABOVE label text:
  #   [____segment1____] [__segment2__] [_seg3_] [_seg4_]
  #   Street Address       City          State    Zip
  #
  # Returns { segments: [...], claimed_blank_indices: Set } so that blanks claimed
  # here are excluded from detect_label_field_pairs (prevents cross-pattern contamination
  # with adjacent "Label ________" patterns like "known as No. ____________").

  def detect_address_segments(page_text_items, page_blank_lines)
    segments = []
    claimed_blank_indices = Set.new

    begin
      # ============================================================
      # STEP 1: Find the address LABEL row
      # ============================================================
      address_label_keywords = {
        'street_address' => ['street address', 'street addr', 'address'],
        'city' => ['city'],
        'state' => ['state'],
        'zip' => ['zip', 'zip code', 'zipcode', 'postal']
      }

      # Score each text item against address keywords
      label_candidates = []
      page_text_items.each_with_index do |item, idx|
        next if item[:text].nil? || item[:text].strip.length > 20
        text_lower = item[:text].strip.downcase

        address_label_keywords.each do |slot_name, keywords|
          if keywords.any? { |kw| text_lower == kw || text_lower.start_with?(kw) }
            est_width = item[:text].strip.length * 0.55
            label_candidates << {
              slot: slot_name,
              text: item[:text].strip,
              x: item[:x],
              y: item[:y],
              width: est_width,
              height: 1.5,
              center_x: item[:x] + (est_width / 2.0),
              text_idx: idx
            }
            break
          end
        end
      end

      return { segments: [], claimed_blank_indices: Set.new } if label_candidates.length < 2

      # Group label candidates by y-coordinate (tight tolerance: 0.8%)
      label_y_groups = {}
      label_candidates.each do |lc|
        matched_y = label_y_groups.keys.find { |y| (y - lc[:y]).abs < 0.8 }
        if matched_y
          label_y_groups[matched_y] << lc
        else
          label_y_groups[lc[:y]] = [lc]
        end
      end

      # Find the best label row: most distinct slots, at least 2
      best_label_row = nil
      best_slot_count = 0
      label_y_groups.each do |_y, labels|
        distinct_slots = labels.map { |l| l[:slot] }.uniq
        if distinct_slots.length > best_slot_count
          best_slot_count = distinct_slots.length
          best_label_row = labels
        end
      end

      return { segments: [], claimed_blank_indices: Set.new } if best_label_row.nil? || best_slot_count < 2

      # Deduplicate: keep one label per slot (leftmost)
      slot_labels = {}
      best_label_row.each do |lc|
        if slot_labels[lc[:slot]].nil? || lc[:x] < slot_labels[lc[:slot]][:x]
          slot_labels[lc[:slot]] = lc
        end
      end

      ordered_slots = slot_labels.values.sort_by { |l| l[:x] }
      label_row_y = ordered_slots.map { |l| l[:y] }.sum / ordered_slots.length.to_f

      Rails.logger.info "[AgreementScan] ADDRESS PARSER: Label row at y=#{label_row_y.round(1)}% " \
        "with #{ordered_slots.length} slots: #{ordered_slots.map { |s| s[:slot] }.join(', ')}"
      ordered_slots.each do |s|
        Rails.logger.info "[AgreementScan]   Label '#{s[:text]}' slot=#{s[:slot]} x=#{s[:x].round(1)}% center_x=#{s[:center_x].round(1)}%"
      end

      # ============================================================
      # STEP 2: Find blank segments STRICTLY above the label row
      # ============================================================
      min_distance_above = 0.8
      max_distance_above = 6.0

      address_blank_candidates = []
      page_blank_lines.each_with_index do |bl, bl_idx|
        distance_above = label_row_y - bl[:y]

        next unless distance_above > min_distance_above && distance_above < max_distance_above
        next unless bl[:width] && bl[:width] > 2.0

        # Must horizontally overlap with the general address area
        area_left = ordered_slots.first[:x] - 5.0
        area_right = ordered_slots.last[:x] + ordered_slots.last[:width] + 15.0
        blank_right = bl[:x] + bl[:width]
        next unless blank_right > area_left && bl[:x] < area_right

        address_blank_candidates << {
          x: bl[:x],
          y: bl[:y],
          width: bl[:width],
          height: bl[:height] || 2.0,
          center_x: bl[:x] + (bl[:width] / 2.0),
          blank_idx: bl_idx,
          original: bl
        }

        Rails.logger.info "[AgreementScan]   Address blank candidate: x=#{bl[:x].round(1)}% y=#{bl[:y].round(1)}% " \
          "w=#{bl[:width].round(1)}% distance_above=#{distance_above.round(1)}%"
      end

      # Log rejected blanks that were close but excluded
      page_blank_lines.each_with_index do |bl, bl_idx|
        distance_above = label_row_y - bl[:y]
        next unless distance_above > 0 && distance_above <= max_distance_above + 3.0
        next if address_blank_candidates.any? { |c| c[:blank_idx] == bl_idx }

        if distance_above <= min_distance_above || distance_above > max_distance_above
          Rails.logger.info "[AgreementScan]   REJECTED blank: x=#{bl[:x].round(1)}% y=#{bl[:y].round(1)}% " \
            "w=#{(bl[:width] || 0).round(1)}% distance_above=#{distance_above.round(1)}% " \
            "(outside band #{min_distance_above}-#{max_distance_above}%)"
        end
      end

      return { segments: [], claimed_blank_indices: Set.new } if address_blank_candidates.empty?

      # ============================================================
      # STEP 3: Group blanks into same-row segments, sort left-to-right
      # ============================================================
      blank_y_groups = {}
      address_blank_candidates.each do |bc|
        matched_y = blank_y_groups.keys.find { |y| (y - bc[:y]).abs < 1.0 }
        if matched_y
          blank_y_groups[matched_y] << bc
        else
          blank_y_groups[bc[:y]] = [bc]
        end
      end

      segment_row = blank_y_groups.values.max_by(&:length) || []
      segment_row.sort_by! { |s| s[:x] }

      Rails.logger.info "[AgreementScan]   Segment row: #{segment_row.length} segments sorted L-to-R"
      segment_row.each_with_index do |s, i|
        Rails.logger.info "[AgreementScan]     Segment[#{i}]: x=#{s[:x].round(1)}% w=#{s[:width].round(1)}% center_x=#{s[:center_x].round(1)}%"
      end

      return { segments: [], claimed_blank_indices: Set.new } if segment_row.empty?

      # ============================================================
      # STEP 4: One-to-one ordered slot mapping
      # ============================================================
      slot_assignments = {}

      if segment_row.length == ordered_slots.length
        # Perfect match: assign by position order
        ordered_slots.each_with_index do |slot_label, idx|
          seg = segment_row[idx]
          slot_assignments[slot_label[:slot]] = {
            label: slot_label,
            segment: seg,
            method: 'ordered_position'
          }
        end
        Rails.logger.info "[AgreementScan]   Mapping method: ordered_position " \
          "(#{segment_row.length} segments = #{ordered_slots.length} slots)"

      elsif segment_row.length > ordered_slots.length
        # More segments than slots: match each slot to nearest segment by center_x
        used_segments = Set.new
        ordered_slots.each do |slot_label|
          best_seg = nil
          best_dist = Float::INFINITY
          segment_row.each_with_index do |seg, seg_idx|
            next if used_segments.include?(seg_idx)
            dist = (seg[:center_x] - slot_label[:center_x]).abs
            if dist < best_dist
              best_dist = dist
              best_seg = { seg: seg, idx: seg_idx }
            end
          end
          if best_seg && best_dist < 20.0
            slot_assignments[slot_label[:slot]] = {
              label: slot_label,
              segment: best_seg[:seg],
              method: 'nearest_center'
            }
            used_segments.add(best_seg[:idx])
          end
        end
        Rails.logger.info "[AgreementScan]   Mapping method: nearest_center " \
          "(#{segment_row.length} segments > #{ordered_slots.length} slots)"

      else
        # Fewer segments than slots: assign by position, skip unmatched slots
        segment_row.each_with_index do |seg, idx|
          if idx < ordered_slots.length
            slot_label = ordered_slots[idx]
            slot_assignments[slot_label[:slot]] = {
              label: slot_label,
              segment: seg,
              method: 'ordered_partial'
            }
          end
        end
        Rails.logger.info "[AgreementScan]   Mapping method: ordered_partial " \
          "(#{segment_row.length} segments < #{ordered_slots.length} slots)"
      end

      # ============================================================
      # STEP 5: Generate strict field geometry
      # ============================================================
      confidence = if slot_assignments.length >= 4
                     0.94
                   elsif slot_assignments.length >= 3
                     0.90
                   else
                     0.85
                   end

      slot_assignments.each do |slot_name, assignment|
        seg = assignment[:segment]
        lbl = assignment[:label]

        # The segment is the blank area ABOVE the label
        # segment.y is the TOP of the blank (smaller number = higher on page)
        # label_row_y is where the labels sit (larger number = lower on page)
        segment_top = seg[:y]
        segment_bottom = seg[:y] + (seg[:height] || 2.0)
        label_top = label_row_y - 0.5  # Buffer above label text

        # Field must stay ABOVE the label row — clip if segment extends into label area
        usable_bottom = [segment_bottom, label_top].min

        inset_x = 0.3
        inset_y = 0.2

        field_x = seg[:x] + inset_x
        field_width = seg[:width] - (inset_x * 2)
        field_y = segment_top + inset_y
        field_height = usable_bottom - field_y - inset_y

        # Clamp height to reasonable range
        field_height = [[field_height, 1.0].max, 3.0].min

        # HARD CHECK: field bottom must be above label text
        field_bottom = field_y + field_height
        if field_bottom > label_top
          field_height = label_top - field_y - 0.2
          field_height = [field_height, 0.8].max
        end

        # HARD CHECK: field must be contained within segment horizontally
        seg_right = seg[:x] + seg[:width]
        field_right = field_x + field_width
        if field_right > seg_right
          field_width = seg_right - field_x - inset_x
        end

        # Debug: verify containment
        final_bottom = field_y + field_height
        overlaps_label = final_bottom > label_row_y
        inside_segment = field_y >= segment_top && final_bottom <= segment_bottom + 0.5

        Rails.logger.info "[AgreementScan]   GEOMETRY #{slot_name}: segment=[y:#{segment_top.round(1)} to " \
          "#{segment_bottom.round(1)}] label_row=#{label_row_y.round(1)} field=[y:#{field_y.round(1)} to " \
          "#{final_bottom.round(1)} h:#{field_height.round(1)}] overlaps_label=#{overlaps_label} " \
          "inside_segment=#{inside_segment}"

        segments << {
          label: lbl[:text],
          label_text: lbl[:text],
          slot: slot_name,
          field_x: field_x.round(2),
          field_y: field_y.round(2),
          field_width: [field_width, 1.0].max.round(2),
          field_height: [field_height, 0.8].max.round(2),
          confidence: confidence,
          pattern_type: 'address_segment',
          match_method: assignment[:method]
        }

        # Claim this blank line by index
        claimed_blank_indices.add(seg[:blank_idx]) if seg[:blank_idx]

        Rails.logger.info "[AgreementScan]   ASSIGNED: #{slot_name} -> x=#{field_x.round(1)}% " \
          "y=#{field_y.round(1)}% w=#{[field_width, 1.0].max.round(1)}% " \
          "h=#{[field_height, 0.8].max.round(1)}% (#{assignment[:method]})"
      end

      Rails.logger.info "[AgreementScan] ADDRESS PARSER COMPLETE: #{segments.length} fields assigned, " \
        "#{claimed_blank_indices.length} blanks claimed"

    rescue => e
      Rails.logger.error "[AgreementScan] Address segment detection error: #{e.message}"
      Rails.logger.error e.backtrace.first(3).join("\n")
    end

    { segments: segments, claimed_blank_indices: claimed_blank_indices }
  end

  # ─── Pattern Detector: Checkbox Squares ────────────────────────────────────────
  #
  # Find small square rectangles (aspect ratio near 1:1, width < 4%) that are checkboxes.

  def detect_checkbox_squares(page_blanks)
    page_blanks.filter_map do |blank|
      next unless blank[:type] == 'box'
      next unless blank[:width] < 4.0 && blank[:height] > 0.5

      # Aspect ratio should be roughly square (between 0.5 and 2.0)
      ratio = blank[:width] / [blank[:height], 0.1].max
      next unless ratio.between?(0.5, 2.0)

      {
        label_text: nil,
        label_x: blank[:x],
        label_y: blank[:y],
        field_x: blank[:x],
        field_y: blank[:y],
        field_width: 2.5,
        field_height: 2.5,
        confidence: 0.94,
        pattern_type: :checkbox_square,
      }
    end
  end

  # ─── Pattern Engine Helpers ──────────────────────────────────────────────────

  # Group text items by similar y-coordinate
  def group_by_y(items, tolerance)
    groups = {}
    items.each do |item|
      y = item[:y]
      matched_key = groups.keys.find { |k| (k - y).abs < tolerance }
      if matched_key
        groups[matched_key] << item
      else
        groups[y] = [item]
      end
    end
    groups
  end

  # Group blank lines by similar y-coordinate
  def group_blanks_by_y(blanks, tolerance)
    groups = {}
    blanks.each do |blank|
      y = blank[:y]
      matched_key = groups.keys.find { |k| (k - y).abs < tolerance }
      if matched_key
        groups[matched_key] << blank
      else
        groups[y] = [blank]
      end
    end
    groups
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

  # Extract the label portion from paragraph-length AcroForm field names.
  # PDF tools sometimes concatenate the real label with adjacent body text.
  # e.g. "Standard Freight ChargeBuyer understands that..." → "Standard Freight Charge"
  # Returns nil if the name is purely body text with no label prefix.
  PARAGRAPH_BODY_MARKERS = [
    /Buyer\s+(?:authorizes|understands|agrees|is\s+financially|consents|hereby|will)/i,
    /Factory\s+Direct\s+Homes/i,
    /Please\s+read/i,
    /All\s+(?:homes|payments|cosmetic|Payments)/i,
    /This\s+(?:notice|agreement|form|is)/i,
    /In\s+the\s+event/i,
    /Unless\s+otherwise/i,
    /Changes\s+may/i,
    /Taxes\s+may/i,
    /By\s+signing\s+below/i,
    /By\s+placing\s+home/i,
    /\bX\s*_{2,}/,  # X followed by underscores (signature lines)
  ].freeze

  def extract_label_prefix(name)
    return name if name.to_s.length <= 50

    PARAGRAPH_BODY_MARKERS.each do |marker|
      match = name.match(marker)
      if match && match.begin(0) > 0
        prefix = name[0...match.begin(0)].strip
        return prefix if prefix.length >= 2
        return nil  # Pure body text, no meaningful prefix
      elsif match && match.begin(0) == 0
        return nil  # Starts with body text = no label
      end
    end

    # No marker found — truncate at 50 chars at word boundary
    name[0..50].sub(/\s+\S*$/, '').strip
  end

  # After mapping, deduplicate fields that map to the same merge_field on the same page.
  # Keeps the field with the shortest (cleanest) label for each merge_field per page area.
  # This eliminates the 8x freight_charge, 5x completion_month problem caused by
  # paragraph-named AcroForm fields that all contain the same keyword.
  # Signer fields that legitimately repeat multiple times per page (initials, signatures, dates)
  # These must NOT be deduplicated — each X____ X____ pair on a disclosure page is a separate field
  DEDUP_EXEMPT_PREFIXES = %w[signer.role. date.today date.contract_date].freeze

  def deduplicate_merge_fields(fields)
    result = []
    # Group by page + merge_field (only dedup mapped fields)
    by_merge = fields.group_by { |f| f[:merge_field] ? [f[:page], f[:merge_field]] : [f[:page], "__unmapped_#{f.object_id}"] }

    by_merge.each do |(page, mf), group|
      # Never dedup unmapped fields, single-instance fields, or signer/date fields
      is_exempt = mf.start_with?('__unmapped_') || DEDUP_EXEMPT_PREFIXES.any? { |prefix| mf.start_with?(prefix) }

      if is_exempt || group.length == 1
        result.concat(group)
      else
        # When two fields share the same merge_field on the same page,
        # prefer the rightmost one (x > 70%) — it's the fill/value widget,
        # not the printed label widget.
        rightmost = group.select { |f| f[:x].to_f > 70 }
        if rightmost.any?
          best = rightmost.min_by { |f| [f[:original_field_name].to_s.length, f[:x].to_f] }
        else
          best = group.min_by { |f| [f[:original_field_name].to_s.length, f[:x].to_f] }
        end
        result << best

        # Convert duplicates to text-input fields (keep them visible, just unmapped)
        # so users can manually fill or reassign them — NO blank/missing fields.
        others = group - [best]
        others.each do |dup_field|
          dup_field[:merge_field] = nil
          dup_field[:auto_fill] = false
        end
        result.concat(others)

        Rails.logger.info "[AcroForm] MERGE-DEDUP '#{mf}' p#{page}: kept '#{best[:original_field_name].to_s[0..40]}' x=#{best[:x]} (#{others.length} duplicates -> text input)"
      end
    end

    converted = result.count { |f| f[:merge_field].nil? && f[:auto_fill] == false }
    Rails.logger.info "[AcroForm] Merge-field dedup: #{fields.length} fields, #{result.count { |f| f[:merge_field].present? }} mapped, #{converted} converted to text input"
    result
  end

  def deduplicate_positions(fields)
    seen = {}

    fields.each do |field|
      # Fields within ~2% are considered the same position
      pos_key = "#{field[:page]}-#{(field[:x] / 2).round}-#{(field[:y] / 2).round}"

      if seen[pos_key]
        existing = seen[pos_key]
        # Keep the one with better mapping quality
        if field[:merge_field].present? && existing[:merge_field].blank?
          seen[pos_key] = field
        elsif field[:auto_fill] && !existing[:auto_fill]
          seen[pos_key] = field
        end
        # Otherwise keep existing (first wins if equal quality)
      else
        seen[pos_key] = field
      end
    end

    seen.values
  end

  # ─── Section-Prefix Disambiguation for Custom Fields ───────────────────────
  # Groups fields by page, finds duplicate labels among unmapped (custom/text-input)
  # fields, and prefixes them with the nearest section header from OCR text data.
  def disambiguate_custom_field_labels(fields, text_map)
    # Only operate on custom fields (no merge_field = text-input fields)
    custom_fields = fields.select { |f| f[:merge_field].nil? }
    return fields if custom_fields.empty?

    by_page = custom_fields.group_by { |f| f[:page] }
    prefixed_count = 0

    by_page.each do |page_num, page_fields|
      # Find labels that appear more than once on this page
      label_counts = page_fields.group_by { |f| f[:label] }
      duplicate_labels = label_counts.select { |_label, group| group.length > 1 }
      next if duplicate_labels.empty?

      # Build section header index from OCR/text data for this page
      page_text = text_map[page_num] || []
      section_headers = extract_section_headers(page_text, page_fields)

      duplicate_labels.each do |label, dupes|
        dupes.each do |field|
          section = find_section_for_field(field, section_headers)
          if section.present?
            field[:label] = "#{section} \u00B7 #{field[:label]}"
            field[:section] = section
            prefixed_count += 1
          else
            field[:label] = "Page #{page_num} \u00B7 #{field[:label]}"
            field[:section] = "Page #{page_num}"
            prefixed_count += 1
          end
        end
      end

      # Populate section metadata for non-duplicate custom fields too (Phase B)
      label_counts.select { |_label, group| group.length == 1 }.each do |_label, group|
        field = group.first
        next if field[:section].present?
        section = find_section_for_field(field, section_headers)
        field[:section] = section if section.present?
      end
    end

    Rails.logger.info "[AcroForm] Label disambiguation: prefixed #{prefixed_count} duplicate custom field labels with section context"
    fields
  end

  # Extract section headers from page text: static text items that aren't AcroForm fields
  # and match common section heading patterns (short, title-like text above groups of fields)
  def extract_section_headers(page_text, page_fields)
    return [] if page_text.blank?

    # Collect Y positions of AcroForm fields to exclude text that overlaps with fields
    field_positions = page_fields.map { |f| { x: f[:x].to_f, y: f[:y].to_f } }

    page_text.select do |item|
      text = item[:text].to_s.strip
      next false if text.length < 3 || text.length > 50
      # Section headers are short, title-like text (1-5 words, often ending with colon)
      word_count = text.split(/\s+/).length
      next false if word_count > 6
      # Exclude items that are at the same position as an AcroForm field (those are field labels)
      ix = item[:x].to_f
      iy = item[:y].to_f
      overlaps_field = field_positions.any? { |fp| (fp[:x] - ix).abs < 3 && (fp[:y] - iy).abs < 1.5 }
      next false if overlaps_field
      # Exclude common non-header patterns (page numbers, checkbox labels, single chars)
      next false if text.match?(/^(Page\s+\d|[xX_\-\.]+|\d+)$/)
      true
    end.sort_by { |item| item[:y].to_f }
  end

  # Find the nearest section header ABOVE a field (by Y position)
  def find_section_for_field(field, section_headers)
    return nil if section_headers.blank?

    fy = field[:y].to_f
    # Find the last section header that appears above this field
    nearest = section_headers.select { |h| h[:y].to_f < fy }.last
    return nil unless nearest

    # Only use if reasonably close (within 15% Y distance — same visual section)
    return nil if (fy - nearest[:y].to_f) > 15

    nearest[:text].to_s.strip.sub(/[:\s]+$/, '')
  end

  # ─── Universal Initials Pairing ──────────────────────────────────────────
  # GENERIC: Works for ANY PDF template. Pairs initials fields by position:
  # On each page, group initials by Y-row (within 2% tolerance), sort by X.
  # Within each row, alternate: index 0 = signer 1, index 1 = signer 2, etc.
  # This handles the common "x_____ x_____" paired initials pattern.
  def pair_initials_by_position(fields)
    initials = fields.select { |f| f[:type] == 'initials' }
    return if initials.empty?

    # Group by page, then by Y-row within each page
    initials.group_by { |f| f[:page] }.each do |_page, page_initials|
      page_initials.group_by { |f| (f[:y].to_f / 2.0).round }.each do |_ygroup, row|
        next if row.length < 2  # Single initials field — leave as-is
        sorted = row.sort_by { |f| f[:x].to_f }
        sorted.each_with_index do |f, idx|
          if idx.even?
            f[:merge_field] = 'signer.role.buyer_1_initials'
            f[:label] = 'Buyer 1 Initials'
          else
            f[:merge_field] = 'signer.role.buyer_2_initials'
            f[:label] = 'Buyer 2 Initials'
          end
          f[:auto_fill] = true
          f[:group] = 'signatures'
        end
      end
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

  # ─── OCR Fallback for Garbled Font Encoding ─────────────────────────────────
  # Some PDFs use custom font encoding (CMap/ToUnicode) that pdf-reader and pdftotext
  # both fail to decode. Labels like "Fireplace" extract as garbled strings.
  # This method renders affected pages to images and uses Tesseract OCR to read
  # the actual printed text, producing label positions for find_nearest_label.
  # GENERIC: works for any PDF template, not just specific ones.

  def ocr_extract_labels(pdf_data, pages)
    result = {}
    return result if pages.empty?

    pdftoppm_path = `which pdftoppm 2>/dev/null`.strip
    tesseract_path = `which tesseract 2>/dev/null`.strip
    unless pdftoppm_path.present? && tesseract_path.present?
      Rails.logger.warn "[AcroForm] OCR fallback unavailable: pdftoppm=#{pdftoppm_path.present?} tesseract=#{tesseract_path.present?}"
      return result
    end

    Dir.mktmpdir('acroform_ocr') do |tmpdir|
      pdf_path = File.join(tmpdir, 'template.pdf')
      File.binwrite(pdf_path, pdf_data)

      pages.each do |page_num|
        begin
          # Render single page to PNG at 200 DPI
          img_prefix = File.join(tmpdir, "page#{page_num}")
          system(pdftoppm_path, '-f', page_num.to_s, '-l', page_num.to_s,
                 '-r', '200', '-png', pdf_path, img_prefix)

          # Find the rendered image (pdftoppm appends -N.png)
          img_file = Dir.glob("#{img_prefix}*.png").first
          unless img_file && File.exist?(img_file)
            Rails.logger.warn "[AcroForm] OCR: pdftoppm failed for page #{page_num}"
            next
          end

          # Get image dimensions for coordinate conversion
          identify_path = `which identify 2>/dev/null`.strip
          if identify_path.present?
            img_info = `#{identify_path} -format "%w %h" #{img_file} 2>/dev/null`.strip.split
            img_width = img_info[0]&.to_f || 0
            img_height = img_info[1]&.to_f || 0
          end

          # Fallback if ImageMagick not available: estimate from 200 DPI letter size
          if img_width.nil? || img_width <= 1
            img_width = 200.0 * 8.5   # Letter width at 200 DPI
            img_height = 200.0 * 11.0  # Letter height at 200 DPI
          end

          # Run Tesseract OCR with TSV output (gives bounding boxes)
          tsv_prefix = File.join(tmpdir, "ocr_p#{page_num}")
          system(tesseract_path, img_file, tsv_prefix, '-l', 'eng', 'tsv',
                 out: File::NULL, err: File::NULL)

          tsv_file = "#{tsv_prefix}.tsv"
          unless File.exist?(tsv_file)
            Rails.logger.warn "[AcroForm] OCR: Tesseract failed for page #{page_num}"
            next
          end

          # Parse TSV: group words into lines, convert pixel coords to percentages
          # CRITICAL: Use composite key (block-par-line) not just line_num.
          # Tesseract assigns line_num=1 to every label in different blocks,
          # so using line_num alone would merge all labels into one giant string.
          labels = []
          current_line_words = []
          current_line_box = { left: 0, top: 0, right: 0, bottom: 0 }
          last_line_key = nil

          File.readlines(tsv_file).drop(1).each do |tsv_line|
            cols = tsv_line.strip.split("\t")
            next if cols.length < 12

            level = cols[0].to_i
            block_num = cols[2].to_i
            par_num = cols[3].to_i
            line_num = cols[4].to_i
            left = cols[6].to_f
            top = cols[7].to_f
            width = cols[8].to_f
            height = cols[9].to_f
            conf = cols[10].to_f
            text = cols[11].to_s.strip

            next if level != 5  # Only word-level entries
            next if text.empty? || conf < 30  # Skip low-confidence garbage

            # Composite line key: block + paragraph + line uniquely identifies a text line
            line_key = "#{block_num}-#{par_num}-#{line_num}"

            # New line? Flush previous
            if line_key != last_line_key && last_line_key && current_line_words.any?
              flush_ocr_line(labels, current_line_words, nil, img_width, img_height)
              current_line_words = []
            end

            # Store word with position data for column-gap splitting
            current_line_words << { text: text, left: left, top: top, width: width, height: height }

            last_line_key = line_key
          end

          # Flush last line
          flush_ocr_line(labels, current_line_words, nil, img_width, img_height) if current_line_words.any?

          result[page_num] = labels
          samples = labels.first(5).map { |l| l[:text] }.join(', ')
          Rails.logger.info "[AcroForm] OCR page #{page_num}: #{labels.length} text labels recovered (e.g., #{samples})"
        rescue => e
          Rails.logger.warn "[AcroForm] OCR failed for page #{page_num}: #{e.message}"
        end
      end
    end

    result
  end

  # Flush accumulated OCR words into label(s).
  # For multi-column forms, a single Tesseract "line" may span both columns.
  # We detect large horizontal gaps between words and split into separate labels.
  # This is generic and works for any multi-column PDF layout.
  COLUMN_GAP_THRESHOLD = 0.15  # 15% of page width = likely a column boundary

  def flush_ocr_line(labels, words_with_pos, _unused_box, img_width, img_height)
    return if words_with_pos.empty?

    # If words_with_pos is an array of strings (old interface), just emit as-is
    if words_with_pos.first.is_a?(String)
      text = words_with_pos.join(' ')
      return if text.length < 2 || text.match?(/^\d+$/)
      # Can't split without position data — just emit
      labels << { text: text, x: 0, y: 0, width: 0 }
      return
    end

    # Split into sub-labels at large horizontal gaps
    current_segment = [words_with_pos.first]
    words_with_pos.drop(1).each do |word|
      prev = current_segment.last
      prev_right = prev[:left] + prev[:width]
      gap = word[:left] - prev_right
      gap_pct = gap / img_width

      if gap_pct > COLUMN_GAP_THRESHOLD
        # Flush current segment as a label
        emit_ocr_segment(labels, current_segment, img_width, img_height)
        current_segment = [word]
      else
        current_segment << word
      end
    end

    # Flush last segment
    emit_ocr_segment(labels, current_segment, img_width, img_height)
  end

  def emit_ocr_segment(labels, segment, img_width, img_height)
    return if segment.empty?
    text = segment.map { |w| w[:text] }.join(' ').strip
    return if text.length < 2 || text.match?(/^\d+$/)

    x_pct = (segment.first[:left] / img_width * 100.0).round(1)
    y_pct = (segment.first[:top] / img_height * 100.0).round(1)
    right = segment.map { |w| w[:left] + w[:width] }.max
    w_pct = ((right - segment.first[:left]) / img_width * 100.0).round(1)

    labels << { text: text, x: x_pct, y: y_pct, width: w_pct }
  end

  # ─── AcroForm Native Field Extraction (PATH A) ──────────────────────────────

  def extract_acroform_fields(pdf_data)
    reader = PDF::Reader.new(StringIO.new(pdf_data))

    root = reader.objects.deref(reader.objects.trailer[:Root])
    acroform = root[:AcroForm]
    return { has_acroform: false, fields: [] } unless acroform

    acroform = reader.objects.deref(acroform)
    raw_fields = acroform[:Fields]
    return { has_acroform: false, fields: [] } unless raw_fields&.any?

    # Build page reference lookup table from the PDF page tree
    page_lookup = build_page_lookup(reader)
    Rails.logger.info "[AcroForm] Built page lookup with #{page_lookup.length} entries"

    fields = []
    extract_fields_recursive(reader, raw_fields, fields, reader.pages, page_lookup)

    Rails.logger.info "[AcroForm] Detected #{fields.length} native fields across #{fields.map { |f| f[:page] }.uniq.length} pages"

    # Log page distribution
    page_distribution = fields.group_by { |f| f[:page] }.transform_values(&:length)
    Rails.logger.info "[AcroForm] Page distribution: #{page_distribution.sort.map { |p, c| "Page #{p}: #{c} fields" }.join(', ')}"

    # Log coordinate conversion samples for first 5 fields
    fields.first(5).each do |f|
      Rails.logger.info "[AcroForm]   Sample: '#{f[:name]}' page=#{f[:page]} pdf_rect=#{f[:pdf_rect]} -> x=#{f[:x]}% y=#{f[:y]}% w=#{f[:width]}% h=#{f[:height]}%"
    end

    { has_acroform: true, fields: fields }
  rescue => e
    Rails.logger.warn "[AcroForm] Extraction failed (falling back to vision): #{e.message}"
    { has_acroform: false, fields: [] }
  end

  def extract_fields_recursive(reader, field_refs, results, pages, page_lookup = {})
    field_refs.each do |field_ref|
      field = reader.objects.deref(field_ref)
      next unless field.is_a?(Hash)

      # Recurse into child fields
      kids = field[:Kids]
      if kids&.any?
        # Pass parent field type down — kids inherit :FT from parent
        kids.each do |kid_ref|
          kid = reader.objects.deref(kid_ref)
          next unless kid.is_a?(Hash)
          kid[:FT] ||= field[:FT] if field[:FT]
          kid[:T] ||= field[:T] if field[:T] && !kid[:T]
        end
        extract_fields_recursive(reader, kids, results, pages, page_lookup)
        next
      end

      field_name = resolve_field_name(reader, field)
      field_type = resolve_field_type(field)
      rect = field[:Rect]
      page_ref = field[:P]

      next unless rect.is_a?(Array) && rect.length == 4

      page_number = resolve_page_number(reader, page_ref, pages, page_lookup)
      page = pages[page_number - 1] if page_number && page_number <= pages.length
      next unless page

      # Get page dimensions using CropBox if available (same pattern as existing code)
      crop_box = page.attributes[:CropBox] || page.attributes[:MediaBox]
      if crop_box.is_a?(Array) && crop_box.length == 4
        origin_x = crop_box[0].to_f
        origin_y = crop_box[1].to_f
        page_width = (crop_box[2].to_f - origin_x).abs
        page_height = (crop_box[3].to_f - origin_y).abs
      else
        origin_x = 0.0
        origin_y = 0.0
        page_width = page.width.to_f
        page_height = page.height.to_f
      end

      next if page_width == 0 || page_height == 0

      # PDF rect: [x1, y1, x2, y2] in points, origin bottom-left
      pdf_x1 = [rect[0], rect[2]].min.to_f
      pdf_y1 = [rect[1], rect[3]].min.to_f
      pdf_x2 = [rect[0], rect[2]].max.to_f
      pdf_y2 = [rect[1], rect[3]].max.to_f

      # Convert to percentage coordinates, origin top-left (matching existing system)
      x_pct = ((pdf_x1 - origin_x) / page_width * 100.0)
      y_pct = ((page_height - (pdf_y2 - origin_y)) / page_height * 100.0)
      width_pct = ((pdf_x2 - pdf_x1) / page_width * 100.0)
      height_pct = ((pdf_y2 - pdf_y1) / page_height * 100.0)

      # Clamp to valid range
      x_pct = [[x_pct, 0].max, 100].min
      y_pct = [[y_pct, 0].max, 100].min

      results << {
        name: field_name,
        type: field_type,
        page: page_number,
        x: x_pct.round(2),
        y: y_pct.round(2),
        width: width_pct.round(2),
        height: height_pct.round(2),
        pdf_rect: rect.map(&:to_f),
        flags: field[:Ff] || 0,
        default_value: field[:V],
        options: field[:Opt],
        max_length: field[:MaxLen],
        source: 'acroform'
      }
    end
  end

  def resolve_field_name(reader, field)
    name = field[:T]
    if name.is_a?(String)
      name.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    elsif name.respond_to?(:to_s) && name.to_s.present?
      name.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    else
      'unnamed_field'
    end
  end

  def resolve_field_type(field)
    ft = field[:FT]
    flags = field[:Ff] || 0

    case ft
    when :Tx
      (flags & (1 << 12)) != 0 ? 'longtext' : 'text'
    when :Btn
      if (flags & (1 << 16)) != 0
        'pushbutton'
      elsif (flags & (1 << 15)) != 0
        'radio'
      else
        'checkbox'
      end
    when :Ch
      (flags & (1 << 17)) != 0 ? 'dropdown' : 'list'
    when :Sig
      'signature'
    else
      'text'
    end
  end

  # Build a lookup table mapping PDF page object references to page numbers.
  # Walks the page tree from the catalog root, handling nested Pages nodes.
  def build_page_lookup(reader)
    lookup = {}

    begin
      root = reader.objects.deref(reader.objects.trailer[:Root])
      pages_dict = reader.objects.deref(root[:Pages])

      if pages_dict&.is_a?(Hash) && pages_dict[:Kids]
        collect_page_refs(reader, pages_dict[:Kids], lookup, 1)
      end
    rescue => e
      Rails.logger.warn "[AcroForm] Page tree walk failed: #{e.message}"
    end

    # Fallback: if tree walk produced nothing, try object-number matching via reader.pages
    if lookup.empty?
      begin
        reader.objects.each do |ref, obj|
          next unless ref.is_a?(PDF::Reader::Reference)
          next unless obj.is_a?(Hash) && obj[:Type] == :Page
          reader.pages.each_with_index do |page, idx|
            # Match by comparing the page dictionary attributes
            if page.attributes[:MediaBox] == obj[:MediaBox] &&
               page.attributes[:Resources].equal?(obj[:Resources])
              lookup[ref] = idx + 1
              lookup[ref.id] = idx + 1
              break
            end
          end
        end
      rescue => e
        Rails.logger.warn "[AcroForm] Fallback page lookup failed: #{e.message}"
      end
    end

    lookup
  end

  def collect_page_refs(reader, kids_refs, lookup, start_page)
    page_num = start_page

    kids_refs.each do |kid_ref|
      kid = reader.objects.deref(kid_ref)
      next unless kid.is_a?(Hash)

      if kid[:Type] == :Pages
        # Intermediate Pages node — recurse into its Kids
        if kid[:Kids]
          page_num = collect_page_refs(reader, kid[:Kids], lookup, page_num)
        end
      elsif kid[:Type] == :Page
        # Leaf Page node — store the reference as lookup key
        if kid_ref.is_a?(PDF::Reader::Reference)
          lookup[kid_ref] = page_num
          lookup[kid_ref.id] = page_num
        end
        page_num += 1
      end
    end

    page_num
  end

  def resolve_page_number(reader, page_ref, pages, page_lookup = {})
    return 1 unless page_ref

    # Direct reference match (most common — field[:P] is a Reference object)
    return page_lookup[page_ref] if page_lookup[page_ref]

    # Match by reference id (integer object number)
    if page_ref.respond_to?(:id) && page_lookup[page_ref.id]
      return page_lookup[page_ref.id]
    end

    # Try dereferencing and matching against lookup keys
    begin
      derefed = reader.objects.deref(page_ref)
      page_lookup.each do |key, page_num|
        next unless key.is_a?(PDF::Reader::Reference)
        begin
          key_derefed = reader.objects.deref(key)
          return page_num if key_derefed.equal?(derefed) || key_derefed == derefed
        rescue
          next
        end
      end
    rescue => e
      Rails.logger.debug "[AcroForm] Page ref deref failed: #{e.message}"
    end

    # Last resort: walk the page tree searching for this specific ref
    if page_ref.respond_to?(:id)
      begin
        root = reader.objects.deref(reader.objects.trailer[:Root])
        pages_dict = reader.objects.deref(root[:Pages])
        if pages_dict&.is_a?(Hash) && pages_dict[:Kids]
          result = find_page_by_ref_id(reader, pages_dict[:Kids], page_ref, 1)
          return result if result
        end
      rescue => e
        Rails.logger.debug "[AcroForm] Page tree search failed: #{e.message}"
      end
    end

    Rails.logger.warn "[AcroForm] Could not resolve page for ref: #{page_ref.inspect}"
    1
  end

  def find_page_by_ref_id(reader, kids_refs, target_ref, start_page)
    page_num = start_page

    kids_refs.each do |kid_ref|
      kid = reader.objects.deref(kid_ref)
      next unless kid.is_a?(Hash)

      if kid[:Type] == :Pages && kid[:Kids]
        result = find_page_by_ref_id(reader, kid[:Kids], target_ref, page_num)
        return result if result
        page_num += (kid[:Count] || 0)
      elsif kid[:Type] == :Page
        if kid_ref == target_ref ||
           (kid_ref.respond_to?(:id) && target_ref.respond_to?(:id) && kid_ref.id == target_ref.id)
          return page_num
        end
        page_num += 1
      end
    end

    nil
  end

  # ─── AcroForm → Scan Result Builder ─────────────────────────────────────────

  ACROFORM_LABEL_MAP = {
    /\bbuyer\s*1\b/i => 'Buyer 1',
    /\bbuyer\s*2\b/i => 'Buyer 2',
    /\bdate\b/i => 'Date',
    /\bdeal\s*#?\b/i => 'Deal Number',
    /\bmailing\s*address\b/i => 'Mailing Address',
    /\bdelivery\s*address\b/i => 'Delivery Address',
    /\bstreet\s*address\b/i => 'Street Address',
    /\bcity\b/i => 'City',
    /\bstate\b/i => 'State',
    /\bzip\b/i => 'Zip',
    /\bphone\b/i => 'Phone',
    /\bcell\b/i => 'Cell',
    /\bsalesperson\b/i => 'Salesperson',
    /\bemail\s*address\s*1\b/i => 'Email Address 1',
    /\bemail\s*address\s*2\b/i => 'Email Address 2',
    /\bemail\b/i => 'Email',
    /\bmake\s*&?\s*model\b/i => 'Make & Model',
    /\byear\b/i => 'Year',
    /\bbedrooms?\b/i => 'Bedrooms',
    /\bbaths?\b/i => 'Baths',
    /\bden\b/i => 'Den',
    /\bserial\s*number\b/i => 'Serial Number',
    /\bnew\s*\/?\s*used\b/i => 'New / Used',
    /\bfloor\s*size\b/i => 'Floor Size',
    /\bhitch\s*size\b/i => 'Hitch Size',
    /\bapprox\.?\s*sq\.?\s*ft\.?\b/i => 'Approx. Sq. Ft.',
    /\bretail\s*price\b/i => 'Retail Price',
    /\bdown\s*payment\b/i => 'Down Payment',
    /\btotal\b/i => 'Total',
    /\bunpaid\s*balance\b/i => 'Unpaid Balance',
    /\bsignature\b/i => 'Signature',
    /\binitials?\b/i => 'Initials',
    /\bmanufacturer\b/i => 'Manufacturer',
    /\bmodel\b/i => 'Model',
    /\bvin\b/i => 'VIN',
    /\brouting\b/i => 'Routing Number',
    /\baccount\b/i => 'Account Number',
    /\blien\s*holder\b/i => 'Lien Holder',
    /\bdriver.?s?\s*license\b/i => 'Drivers License',
    /\bdob\b|\bdate\s*of\s*birth\b/i => 'Date of Birth',
    /\bein\b/i => 'EIN',
    /\bcheck\s*box\b/i => 'Checkbox',
  }.freeze

  ACROFORM_TYPE_MAP = {
    'text' => 'text',
    'longtext' => 'text',
    'checkbox' => 'checkbox',
    'radio' => 'checkbox',
    'signature' => 'signature',
    'dropdown' => 'text',
    'list' => 'text',
  }.freeze

  def build_acroform_scan_result(acroform_fields, max_pages, pdf_data)
    # Extract text positions for label context (helps map generic-named fields)
    text_map = {}
    raw_text_map = {}
    @garbled_pages = []  # Pages where text extraction produces unreadable encoding
    begin
      raw_text_map, _ = extract_text_with_positions(pdf_data)

      # Sanitize text items and detect pages with garbled font encoding
      raw_text_map.each do |page, items|
        text_map[page] = sanitize_text_for_labeling(items)
      end
      raw_total = raw_text_map.values.sum(&:length)
      clean_total = text_map.values.sum(&:length)
      Rails.logger.info "[AcroForm] Text: #{raw_total} raw -> #{clean_total} clean labels (filtered #{raw_total - clean_total} garbage/body items)"

      # Detect garbled pages: pages that have AcroForm fields but <3 readable text labels
      # This indicates custom font encoding that pdf-reader can't decode
      all_field_pages = acroform_fields.map { |f| f[:page] }.uniq
      all_field_pages.each do |pg|
        field_count = acroform_fields.count { |f| f[:page] == pg }
        label_count = (text_map[pg] || []).length
        if field_count >= 5 && label_count < 3
          @garbled_pages << pg
        end
      end

      # OCR fallback for garbled pages: render page to image + tesseract
      if @garbled_pages.any?
        Rails.logger.info "[AcroForm] Garbled text on pages #{@garbled_pages.join(', ')} (custom font encoding) — attempting OCR fallback"
        ocr_labels = ocr_extract_labels(pdf_data, @garbled_pages)
        @garbled_pages.each do |pg|
          if ocr_labels[pg]&.any?
            text_map[pg] = ocr_labels[pg]
            Rails.logger.info "[AcroForm] OCR recovered #{ocr_labels[pg].length} labels for page #{pg}"
          else
            Rails.logger.warn "[AcroForm] OCR returned no labels for page #{pg}"
          end
        end
      end
    rescue => e
      Rails.logger.warn "[AcroForm] Text extraction failed (non-fatal): #{e.message}"
    end

    # Pre-filter: remove AcroForm fields that overlap with printed body text
    # Skip this filter for garbled pages (the "text" is encoding noise, not real paragraphs)
    if raw_text_map.any?
      pre_count = acroform_fields.length
      acroform_fields = filter_body_text_overlap_fields(acroform_fields, raw_text_map, @garbled_pages)
      Rails.logger.info "[AcroForm] Body-text overlap filter: #{pre_count} -> #{acroform_fields.length} (removed #{pre_count - acroform_fields.length} fields on printed text)"
    end

    mapped = map_acroform_to_scan_fields(acroform_fields, text_map)

    total_pages = mapped.map { |f| f[:page] }.max || 1
    pages_to_scan = [max_pages, total_pages].min

    # Filter to scanned pages
    mapped = mapped.select { |f| f[:page] <= pages_to_scan }

    # Disambiguate duplicate custom field labels using section headers from OCR/text data
    mapped = disambiguate_custom_field_labels(mapped, text_map)

    page_classifications = classify_pages(mapped, total_pages)

    Rails.logger.info "[AcroForm] Scan complete: #{mapped.length} fields across #{pages_to_scan} pages"

    sanitize_for_json({
      fields: mapped,
      pages_scanned: pages_to_scan,
      total_pages: total_pages,
      page_classifications: page_classifications,
      scan_source: 'acroform',
    })
  end

  def map_acroform_to_scan_fields(acroform_fields, text_map = {})
    # Filter out non-input AcroForm fields:
    # - pushbuttons (no type mapping)
    # - read-only fields (Ff bit 0) — labels, headers, decorative elements
    # - fields with pre-filled static values (company name, address, etc.)
    # - tiny decorative fields (width or height < 0.5%)
    usable = acroform_fields.select do |f|
      # Must have valid type OR be a nil-type widget on appliance/color pages (3-4) with valid geometry
      has_type = ACROFORM_TYPE_MAP[f[:type]]
      nil_type_on_form_page = f[:type].nil? && [3, 4].include?(f[:page]) && f[:width].to_f > 1.0 && f[:height].to_f > 0.5
      next false unless has_type || nil_type_on_form_page
      next false if (f[:flags].to_i & 1) != 0         # Skip read-only fields
      next false if f[:width].to_f < 0.5 || f[:height].to_f < 0.3  # Skip tiny decorative fields
      # Skip fields with pre-filled static values (company headers, printed labels)
      if f[:default_value].present?
        val = f[:default_value].to_s.strip
        # Keep fields with common placeholder values
        next true if val.blank? || val == '' || val == ' '
        # Skip fields whose value matches the company header or static content
        next false if val.length > 30  # Long pre-filled text = not an input field
      end
      true
    end
    Rails.logger.info "[AcroForm] Filtered: #{acroform_fields.length} total -> #{usable.length} usable (removed #{acroform_fields.length - usable.length} read-only/decorative/pre-filled)"

    # ─── Paragraph Name Cleaning ────────────────────────────────────────────
    # Many AcroForm fields have names like "Standard Freight ChargeBuyer understands..."
    # Extract the real label prefix and reject pure body-text fields.
    pre_paragraph = usable.length
    usable.each do |f|
      raw_name = f[:name].to_s
      if raw_name.length > 50
        prefix = extract_label_prefix(raw_name)
        if prefix.nil?
          f[:_paragraph_body] = true  # Mark for rejection
        else
          f[:clean_name] = prefix
        end
      end
    end

    # Reject paragraph-body fields that are wide (>10% width = not an initials box)
    usable.reject! do |f|
      if f[:_paragraph_body] && f[:width].to_f > 10
        Rails.logger.debug "[AcroForm] PARAGRAPH-REJECT '#{f[:name].to_s[0..60]}...' p#{f[:page]} (pure body text, w=#{f[:width]}%)"
        true
      else
        false
      end
    end

    # Reject company header/address fields
    usable.reject! do |f|
      name = f[:name].to_s
      if name.match?(/^\d{3,5}\s*(?:State|St|N|S|E|W)\s+(?:Road|Rd|St|Ave|Dr|Blvd)/i) ||
         name.match?(/Auburn.*IN.*46706/i) ||
         name.match?(/Factory\s+Direct\s+Homes\s+Center/i)
        Rails.logger.debug "[AcroForm] HEADER-REJECT '#{name[0..60]}' p#{f[:page]} (company header)"
        true
      else
        false
      end
    end
    Rails.logger.info "[AcroForm] Paragraph/header filter: #{pre_paragraph} -> #{usable.length} (removed #{pre_paragraph - usable.length})"

    by_page = usable.group_by { |f| f[:page] }

    all_mapped = []

    by_page.each do |page_num, page_fields|
      page_text = text_map[page_num] || []
      mapped = begin
        case page_num
        when 1  then map_page1_fields(page_fields, page_text)
        when 2  then map_addendum_a_fields(page_fields, page_text)
        when 3  then map_appliance_fields(page_fields, page_text)
        when 4  then map_color_fields(page_fields, page_text)
        when 13 then map_tires_axles_fields(page_fields, page_text)
        when 14 then map_shipping_fields(page_fields, page_text)
        when 15 then map_title_info_fields(page_fields, page_text)
        else         map_signature_page_fields(page_fields, page_num, page_text)
        end
      rescue => e
        Rails.logger.warn "[AcroForm] Page #{page_num} mapping failed, using fallback: #{e.message}"
        map_generic_fields(page_fields, page_text)
      end

      all_mapped.concat(mapped)
    end

    # ─── Universal Signature/Date Pre-Pass ───────────────────────────────────
    # Page-specific mappers (3, 4, 13, 15) don't check for Signature_es_ fields.
    # Fix them universally here before dedup runs.
    all_mapped.each do |f|
      orig = f[:original_field_name].to_s

      # Signature_es_ fields (DocuSign-style) on ANY page
      if orig.match?(/Signature\d*_es_/i)
        f[:type] = 'signature'
        f[:auto_fill] = true
        f[:group] = 'signatures'
        if orig.match?(/[13579]_es_/) # Odd = row 1 (rep/buyer1)
          f[:merge_field] = f[:x].to_f < 50 ? 'signer.role.dealer_rep' : 'signer.role.buyer_1'
          f[:label] = f[:x].to_f < 50 ? 'Dealer Rep Signature' : 'Buyer 1 Signature'
        else # Even = row 2 (manager/buyer2)
          f[:merge_field] = f[:x].to_f < 50 ? 'signer.role.dealer_manager' : 'signer.role.buyer_2'
          f[:label] = f[:x].to_f < 50 ? 'Manager Signature' : 'Buyer 2 Signature'
        end
      # Date_N fields in signature zone (y > 75%) on any page
      elsif orig.match?(/^Date_\d+$/i) && f[:y].to_f > 75
        f[:type] = 'date'
        f[:merge_field] = 'date.today'
        f[:label] = 'Signing Date'
        f[:auto_fill] = true
        f[:group] = 'signatures'
      # BUYER 1 signature fields in footer zone (y > 75%) on any page
      elsif orig.match?(/\bBUYER\s*1(?:\b|_)/i) && f[:y].to_f > 75
        f[:type] = 'signature'
        f[:merge_field] = 'signer.role.buyer_1'
        f[:label] = 'Buyer 1 Signature'
        f[:auto_fill] = true
        f[:group] = 'signatures'
      # BUYER 2 signature fields in footer zone (y > 75%) on any page
      elsif orig.match?(/\bBUYER\s*2(?:\b|_)/i) && f[:y].to_f > 75
        f[:type] = 'signature'
        f[:merge_field] = 'signer.role.buyer_2'
        f[:label] = 'Buyer 2 Signature'
        f[:auto_fill] = true
        f[:group] = 'signatures'
      # Representative fields in footer zone on any page
      elsif orig.match?(/Representative/i) && f[:y].to_f > 75
        f[:type] = 'signature'
        f[:merge_field] = 'signer.role.dealer_rep'
        f[:label] = 'Dealer Rep Signature'
        f[:auto_fill] = true
        f[:group] = 'signatures'
      # Manager fields in footer zone on any page
      elsif orig.match?(/Manager/i) && f[:y].to_f > 75
        f[:type] = 'signature'
        f[:merge_field] = 'signer.role.dealer_manager'
        f[:label] = 'Manager Signature'
        f[:auto_fill] = true
        f[:group] = 'signatures'
      end
    end

    # ─── Universal Initials Pairing ───────────────────────────────────────────
    # Runs AFTER per-page mapping. Pairs initials by Y-row position on every page.
    # This is generic — no hardcoded page numbers. Works for any document layout.
    pair_initials_by_position(all_mapped)

    # ─── Metrics & Diagnostics ───────────────────────────────────────────────
    auto_count = all_mapped.count { |f| f[:auto_fill] }
    manual_count = all_mapped.count { |f| !f[:auto_fill] }
    mapped_count = all_mapped.count { |f| f[:merge_field].present? }
    unmapped_count = all_mapped.count { |f| f[:merge_field].nil? }
    Rails.logger.info "[AcroForm] Stats: #{all_mapped.length} total | #{mapped_count} mapped | #{unmapped_count} unmapped | #{auto_count} auto-fill"

    # Merge source breakdown
    merge_prefixes = all_mapped.select { |f| f[:merge_field] }.map { |f| f[:merge_field].split('.').first }.tally
    Rails.logger.info "[AcroForm] Merge sources: #{merge_prefixes.map { |k, v| "#{k}: #{v}" }.join(', ')}"

    # Type breakdown
    type_dist = all_mapped.group_by { |f| f[:type] }.transform_values(&:length)
    Rails.logger.info "[AcroForm] Field types: #{type_dist.map { |t, c| "#{t}: #{c}" }.join(', ')}"

    # Duplicate merge_field collision detection
    merge_field_counts = all_mapped.select { |f| f[:merge_field] }
                                   .group_by { |f| f[:merge_field] }
                                   .select { |_, fields| fields.length > 1 }
    if merge_field_counts.any?
      Rails.logger.info "[AcroForm] DUPLICATE MERGE FIELDS (#{merge_field_counts.length} collisions):"
      merge_field_counts.each do |mf, fields|
        pages = fields.map { |f| f[:page] }.uniq.sort
        Rails.logger.info "[AcroForm]   #{mf} -> #{fields.length}x on pages #{pages.join(',')}"
      end
    end

    # Log sample of mapped fields
    all_mapped.select { |f| f[:merge_field] }.first(15).each do |f|
      Rails.logger.info "[AcroForm]   MAPPED: '#{f[:original_field_name]}' -> #{f[:merge_field]} (#{f[:label]}) p#{f[:page]}"
    end

    # Log sample of unmapped fields
    unmapped = all_mapped.select { |f| f[:merge_field].nil? }
    if unmapped.any?
      Rails.logger.info "[AcroForm]   UNMAPPED (#{unmapped.length} fields, first 10):"
      unmapped.first(10).each do |f|
        Rails.logger.info "[AcroForm]     '#{f[:original_field_name]}' label='#{f[:label]}' p#{f[:page]} x=#{f[:x]} y=#{f[:y]}"
      end
    end

    # Deduplicate by merge_field (eliminates 8x freight_charge, 5x completion_month, etc.)
    all_mapped = deduplicate_merge_fields(all_mapped)
    deduplicate_positions(all_mapped)
  end

  # ─── Page-Specific Field Mappers ─────────────────────────────────────────────

  # Page 1: Main purchase agreement - buyer info, inventory, pricing breakdown
  def map_page1_fields(page_fields, page_text = [])
    # PRICING LOGIC:
    # Retail Price = vehicle.msrp (home price BEFORE discounts, from inventory)
    # Factory Direct Savings = deal discount (calculated from deal, not double-counted)
    # Addendum A = deal.addendum_total (from deal_products - add-ons entered in deal)
    # All other discounts/fees come from the deal record
    # Formulas: Sub Total 1 = Retail - Discount, Sub Total 2 = ST1 + Addendum - discounts,
    #           Total = ST2 + Freight + Setup + Fees + Taxes, Unpaid = Total - Down Payment
    pricing_merge = {
      /retail\s*price/i            => { merge: 'vehicle.msrp',                  type: 'currency' },
      /factory\s*direct\s*saving/i => { merge: 'deal.dealer_discount',           type: 'currency' },
      /sub\s*total\s*1/i           => { merge: 'deal.subtotal_1',               type: 'currency' },
      /addendum.*(?:a|upgrade)/i   => { merge: 'deal.addendum_total',           type: 'currency' },
      /sales\s*event/i             => { merge: 'deal.sales_event_discount',     type: 'currency' },
      /manager\s*discount/i        => { merge: 'deal.manager_discount',         type: 'currency' },
      /preferred\s*payment/i       => { merge: 'deal.preferred_payment_discount', type: 'currency' },
      /multi.?unit\s*discount/i    => { merge: 'deal.multi_unit_discount',      type: 'currency' },
      /sub\s*total\s*2/i           => { merge: 'deal.subtotal_2',               type: 'currency' },
      /(?:standard\s+)?freight/i   => { merge: 'deal.delivery_fee',             type: 'currency' },
      /setup/i                     => { merge: 'deal.setup_fee',                type: 'currency' },
      /extended\s*service/i        => { merge: 'deal.accessories_total',        type: 'currency' },
      /document\s*fee/i            => { merge: 'deal.doc_fee',                  type: 'currency' },
      /\btaxe?s\b/i                => { merge: 'deal.tax_amount',               type: 'currency' },
      /\btotal\b/i                 => { merge: 'deal.total_amount',             type: 'currency' },
      /down\s*payment/i            => { merge: 'deal.down_payment',             type: 'currency' },
      /additional\s*payment/i      => { merge: 'deal.additional_payment',       type: 'currency' },
      /unpaid\s*balance/i          => { merge: 'deal.unpaid_balance',           type: 'currency' },
    }

    # Map fill_* fields (right-column $ inputs) to pricing rows based on Y-position
    # These are the actual value input cells next to the labeled pricing rows
    fill_pricing_map = [
      { y_min: 19.0, y_max: 21.5, merge: 'vehicle.msrp',                     label: 'Retail Price' },
      { y_min: 21.5, y_max: 23.5, merge: 'deal.dealer_discount',             label: 'Factory Direct Savings' },
      { y_min: 26.0, y_max: 28.0, merge: 'deal.addendum_total',              label: 'Addendum A Upgrades' },
      { y_min: 28.0, y_max: 29.5, merge: 'deal.sales_event_discount',        label: 'Sales Event Savings' },
      { y_min: 29.5, y_max: 31.5, merge: 'deal.manager_discount',            label: 'Manager Discount' },
      { y_min: 31.5, y_max: 33.0, merge: 'deal.preferred_payment_discount',  label: 'Preferred Payment Discount' },
      { y_min: 33.0, y_max: 35.0, merge: 'deal.multi_unit_discount',         label: 'Multi-Unit Discount' },
      { y_min: 45.0, y_max: 48.0, merge: 'deal.accessories_total',           label: 'Extended Service' },
      { y_min: 56.0, y_max: 59.0, merge: 'deal.total_amount',                label: 'Total' },
      { y_min: 59.0, y_max: 61.0, merge: 'deal.down_payment',                label: 'Down Payment' },
      { y_min: 61.0, y_max: 63.0, merge: 'deal.additional_payment',          label: 'Additional Payment' },
    ]

    buyer_merge = {
      /\bbuyer\s*1\b/i   => { merge: 'contact.full_name',       group: 'buyer' },
      /\bbuyer\s*2\b/i   => { merge: 'contact2.full_name',      group: 'buyer' },
      /\bdeal\b\s*(?:#|number)?$/i => { merge: 'deal.deal_number', group: 'general' },
      /\bcell\b$/i       => { merge: 'contact.cell_phone',      group: 'buyer' },
      /salesperson/i     => { merge: 'deal.salesperson',        group: 'general' },
    }

    inventory_merge = {
      /make\s*&?\s*model/i  => { merge: 'inventory.make_model',     group: 'unit' },
      /manufacturer/i       => { merge: 'inventory.manufacturer',   group: 'unit' },
      /\bmodel\b/i          => { merge: 'inventory.model',          group: 'unit' },
      /\byear\b/i           => { merge: 'inventory.year',           group: 'unit' },
      /serial\s*number/i    => { merge: 'inventory.serial_number',  group: 'unit' },
      /\bvin\b/i            => { merge: 'inventory.vin',            group: 'unit' },
      /bedroom/i            => { merge: 'inventory.bedrooms',       group: 'unit' },
      /bath/i               => { merge: 'inventory.baths',          group: 'unit' },
      /\bden\b/i            => { merge: 'inventory.den',            group: 'unit' },
      /new\s*\/?\s*used/i   => { merge: 'inventory.condition',      group: 'unit' },
      /floor\s*size/i       => { merge: 'inventory.floor_size',     group: 'unit' },
      /hitch\s*size/i       => { merge: 'inventory.hitch_size',     group: 'unit' },
      /approx.*sq/i         => { merge: 'inventory.approx_sqft',    group: 'unit' },
    }

    address_merge = {
      'mailing' => {
        city: 'contact.city', state: 'contact.state', zip: 'contact.zip',
        phone: 'contact.phone', address: 'contact.street'
      },
      'delivery' => {
        city: 'property.city', state: 'property.state', zip: 'property.zip',
        phone: 'contact.cell_phone', address: 'property.street', cell: 'contact.cell_phone'
      }
    }

    page_fields.map do |f|
      name = f[:name].to_s.strip
      # Use cleaned prefix for paragraph-named fields (prevents body text matching)
      match_name = f[:clean_name] || name
      label = infer_label_from_name(match_name)
      is_generic = label.match?(/^(Text|Fill|Check\s*Box|Signature)\s*\d*$/i) || label == match_name

      # For generic-named fields, find nearby printed text label
      if is_generic && page_text.any?
        nearby = find_nearest_label(f, page_text)
        if nearby.present?
          label = nearby.strip
          ACROFORM_LABEL_MAP.each do |pattern, mapped_label|
            if nearby.match?(pattern)
              label = mapped_label
              break
            end
          end
        end
      end

      scan_type = ACROFORM_TYPE_MAP[f[:type]] || 'text'
      merge_field = nil
      auto_fill = false
      group = infer_group_from_label(label, 1)

      # EMAIL fields — must check BEFORE address section ("Email Address" contains "address")
      if match_name.match?(/email\s*address\s*1/i) || label.match?(/email\s*address\s*1/i)
        merge_field = 'contact.email'
        auto_fill = true
        group = 'buyer'
      elsif match_name.match?(/email\s*address\s*2/i) || label.match?(/email\s*address\s*2/i)
        merge_field = 'contact2.email'
        auto_fill = true
        group = 'buyer'
      elsif match_name.match?(/\bemail\b/i) && !match_name.match?(/\baddress\b.*\bemail\b/i)
        merge_field = 'contact.email'
        auto_fill = true
        group = 'buyer'
      end

      # Try pricing fields (match against resolved label AND cleaned name, NOT paragraph body)
      unless merge_field
        pricing_merge.each do |pattern, info|
          if label.match?(pattern) || match_name.match?(pattern)
            merge_field = info[:merge]
            scan_type = info[:type]
            auto_fill = true
            group = 'pricing'
            break
          end
        end
      end

      # Address fields: distinguish mailing vs delivery by y-position
      # Mailing row ~y:10.4, Delivery row ~y:12.4, Salesperson row ~y:14.5
      unless merge_field
        if label.match?(/\b(city|state|zip|phone|cell|address|street)\b/i) &&
           !label.match?(/email/i)  # Don't catch "Email Address" here
          row_type = f[:y] < 11.5 ? 'mailing' : 'delivery'
          field_type = if label.match?(/city/i) then :city
                       elsif label.match?(/state/i) then :state
                       elsif label.match?(/zip/i) then :zip
                       elsif label.match?(/cell/i) then :cell
                       elsif label.match?(/phone/i) then :phone
                       elsif label.match?(/address|street/i) then :address
                       end
          if field_type && address_merge[row_type]&.dig(field_type)
            merge_field = address_merge[row_type][field_type]
            auto_fill = true
            group = row_type == 'mailing' ? 'buyer' : 'delivery'
          end
        end
      end

      # Try buyer fields
      unless merge_field
        buyer_merge.each do |pattern, info|
          if label.match?(pattern) || match_name.match?(pattern)
            merge_field = info[:merge]
            auto_fill = true
            group = info[:group]
            break
          end
        end
      end

      # Try inventory fields
      unless merge_field
        inventory_merge.each do |pattern, info|
          if label.match?(pattern) || match_name.match?(pattern)
            merge_field = info[:merge]
            auto_fill = true
            group = info[:group]
            break
          end
        end
      end

      # Date fields — separate "date type" from "auto-fill date.today"
      # Only auto-fill with date.today for contract date in header or signature dates
      # Other date fields (DOB, lien date, completion date) are date-TYPE but not date.today
      if merge_field.nil? && (match_name.match?(/\bdate\b/i) && !match_name.match?(/update|mandate/i))
        name_word_count = match_name.split(/\s+/).length
        label_word_count = label.split(/\s+/).length
        # Only match if the field name is short (actual date field, not paragraph containing "date")
        if name_word_count <= 3 || (label.match?(/\bdate\b/i) && label_word_count <= 3)
          scan_type = 'date'
          if f[:y] < 10  # Header area = contract date
            merge_field = 'date.contract_date'
            auto_fill = true
          elsif f[:y] > 85  # Signature block area = signing date
            merge_field = 'date.today'
            auto_fill = true
          else
            # Mid-page date field = just mark as date type, no auto-fill
            merge_field = nil
            auto_fill = false
          end
          group = 'general'
        end
      end

      # Completion month
      if merge_field.nil? && (label.match?(/completion\s*month/i) || match_name.match?(/completion/i))
        merge_field = 'deal.completion_month'
        label = 'Completion Month' if is_generic
        auto_fill = true
      end

      # Map fill_* fields to pricing rows by Y-position
      if merge_field.nil? && name.match?(/^fill_\d+$/i) && f[:x] > 70
        fill_pricing_map.each do |row|
          if f[:y] >= row[:y_min] && f[:y] < row[:y_max]
            merge_field = row[:merge]
            label = row[:label]
            scan_type = 'currency'
            auto_fill = true
            group = 'pricing'
            break
          end
        end
      end

      # Notations & Remarks
      if merge_field.nil? && (label.match?(/notation|remark/i) ||
         (f[:y].between?(72, 80) && f[:x] < 50 && f[:width] > 30))
        merge_field = 'deal.notes'
        label = 'Notations & Remarks' if is_generic
      end

      # Signatures: role-based
      if scan_type == 'signature' || f[:type] == 'signature'
        scan_type = 'signature'
        auto_fill = true
        group = 'signatures'
        if f[:x] < 40
          if name.match?(/manager/i) || label.match?(/manager/i)
            merge_field = 'signer.role.dealer_manager'
            label = 'Manager Signature'
          else
            merge_field = 'signer.role.dealer_rep'
            label = 'Dealer Rep Signature'
          end
        else
          if name.match?(/buyer\s*2/i) || label.match?(/buyer\s*2/i) || (f[:y] > 90 && f[:x] > 50)
            merge_field = 'signer.role.buyer_2'
            label = 'Buyer 2 Signature'
          else
            merge_field = 'signer.role.buyer_1'
            label = 'Buyer 1 Signature'
          end
        end
      end

      # Initials: classify as initials type (universal pair_initials_by_position
      # will assign buyer_1 vs buyer_2 based on Y-row pairing afterward)
      if merge_field.nil? && (label.match?(/initial/i) || name.match?(/initial/i) ||
         (f[:width] && f[:width] < 8 && f[:height] && f[:height] < 5 && scan_type != 'signature'))
        scan_type = 'initials'
        merge_field = 'signer.role.buyer_1_initials'  # default; universal pairing will fix
        label = 'Buyer 1 Initials'
        auto_fill = true
        group = 'signatures'
      end

      build_mapped_field(f, label: label, type: scan_type, group: group,
                         merge_field: merge_field, auto_fill: auto_fill)
    end
  end

  # Page 2: Addendum A - line-item table of upgrades/add-ons
  def map_addendum_a_fields(page_fields, page_text = [])
    sorted = page_fields.sort_by { |f| [f[:y], f[:x]] }

    header_fields = sorted.select { |f| f[:y] < 8 }
    footer_fields = sorted.select { |f| f[:y] > 85 }
    line_item_fields = sorted.select { |f| f[:y] >= 8 && f[:y] <= 85 }

    mapped = []

    # Header: Customer name (left), Model (right)
    header_fields.each do |f|
      if f[:x] < 50
        mapped << build_mapped_field(f, label: 'Customer', type: 'text', group: 'buyer',
                                     merge_field: 'contact.full_name', auto_fill: true)
      else
        mapped << build_mapped_field(f, label: 'Model', type: 'text', group: 'unit',
                                     merge_field: 'inventory.model', auto_fill: true)
      end
    end

    # Line items: group into rows, pair description (wide) + price (narrow)
    rows = group_fields_into_rows(line_item_fields, y_tolerance: 1.5)
    item_number = 0

    rows.each do |row|
      next if row.empty?
      row.sort_by! { |f| f[:x] }

      item_number += 1

      if row.length >= 2
        desc_field = row.max_by { |f| f[:width] }
        price_field = row.min_by { |f| f[:width] }

        mapped << build_mapped_field(desc_field,
                                     label: "Addendum A Item #{item_number} Description",
                                     type: 'text', group: 'pricing',
                                     merge_field: "addendum_a.item_#{item_number}_description",
                                     auto_fill: true)
        mapped << build_mapped_field(price_field,
                                     label: "Addendum A Item #{item_number} Price",
                                     type: 'currency', group: 'pricing',
                                     merge_field: "addendum_a.item_#{item_number}_price",
                                     auto_fill: true)
      else
        f = row.first
        if f[:width] > 40
          mapped << build_mapped_field(f,
                                       label: "Addendum A Item #{item_number} Description",
                                       type: 'text', group: 'pricing',
                                       merge_field: "addendum_a.item_#{item_number}_description",
                                       auto_fill: true)
        else
          mapped << build_mapped_field(f,
                                       label: "Addendum A Item #{item_number} Price",
                                       type: 'currency', group: 'pricing',
                                       merge_field: "addendum_a.item_#{item_number}_price",
                                       auto_fill: true)
        end
      end
    end

    # Footer: total, initials, date
    footer_fields.sort_by { |f| [f[:y], f[:x]] }.each do |f|
      if f[:x] > 60 && f[:width] < 25
        mapped << build_mapped_field(f, label: 'Addendum A Total', type: 'currency', group: 'pricing',
                                     merge_field: 'addendum_a.total', auto_fill: true)
      elsif f[:type] == 'signature' || (f[:width] < 15 && f[:height] < 4)
        if f[:x] < 35
          mapped << build_mapped_field(f, label: 'Buyer 1 Initials', type: 'initials', group: 'signatures',
                                       merge_field: 'signer.role.buyer_1_initials', auto_fill: true)
        elsif f[:x] < 55
          mapped << build_mapped_field(f, label: 'Buyer 2 Initials', type: 'initials', group: 'signatures',
                                       merge_field: 'signer.role.buyer_2_initials', auto_fill: true)
        else
          mapped << build_mapped_field(f, label: 'Addendum A Date', type: 'date', group: 'general',
                                       merge_field: 'date.today', auto_fill: true)
        end
      else
        mapped << build_mapped_field(f, label: 'Addendum A Date', type: 'date', group: 'general',
                                     merge_field: 'date.today', auto_fill: true)
      end
    end

    Rails.logger.info "[AcroForm] Addendum A: #{item_number} line item rows, #{mapped.length} total fields"
    mapped
  end

  # Page 3: Appliance & Electrical Worksheet (generic — works for any template)
  # Uses regex label matching against text extracted via pdf-reader or OCR fallback.
  APPLIANCE_LABEL_MAP = {
    /\bfireplace\b/i                   => { label: 'Fireplace',          merge: 'vehicle.fireplace' },
    /\bwasher\b/i                      => { label: 'Washer',             merge: 'vehicle.clothes_washer' },
    /\bdryer\s*hookup\s*type\b/i       => { label: 'Dryer Hookup Type', merge: 'vehicle.clothes_dryer' },
    /\bdryer\s*hookup\b/i              => { label: 'Dryer Hookup',      merge: 'vehicle.clothes_dryer' },
    /\bdryer\b/i                       => { label: 'Dryer',              merge: 'vehicle.clothes_dryer' },
    /\bfurnace\s*type\b/i              => { label: 'Furnace Type',      merge: 'vehicle.heating_type' },
    /\bfurnace\b/i                     => { label: 'Furnace',            merge: 'vehicle.heating_type' },
    /\bdishwasher\s*(?:ready|door)\b/i => { label: 'Dishwasher',        merge: 'vehicle.dishwasher' },
    /\bdishwasher\b/i                  => { label: 'Dishwasher',        merge: 'vehicle.dishwasher' },
    /\bgarbage\s*disposal\b/i          => { label: 'Garbage Disposal',  merge: 'vehicle.garbage_disposal' },
    /\bmicrowave\b/i                   => { label: 'Microwave',          merge: 'vehicle.microwave' },
    /\bice\s*maker\b/i                 => { label: 'Ice Maker',          merge: 'vehicle.refrigerator' },
    /\bheat\s*pump\s*ready\b/i         => { label: 'Heat Pump Ready',   merge: 'vehicle.central_air' },
    /\bac\s*ready\b/i                  => { label: 'AC Ready',           merge: 'vehicle.central_air' },
    /\bfreezer\s*plug\b/i              => { label: 'Freezer Plug',      merge: 'vehicle.refrigerator' },
    /\bwater\s*heater\s*size\b/i       => { label: 'Water Heater Size', merge: 'vehicle.water_heater_type' },
    /\bwater\s*heater\b/i              => { label: 'Water Heater',      merge: 'vehicle.water_heater_type' },
    /\bductwork\b/i                    => { label: 'Ductwork',           merge: 'vehicle.heating_type' },
    /\brange\s*hookup\s*type\b/i       => { label: 'Range Hookup Type', merge: 'vehicle.oven' },
    /\brange\s*hookup\b/i              => { label: 'Range Hookup',      merge: 'vehicle.oven' },
    /\brange\s*type\b/i                => { label: 'Range Type',        merge: 'vehicle.oven' },
    /\brange\b|stove/i                 => { label: 'Range',              merge: 'vehicle.oven' },
    /\bappliance\s*color\b/i           => { label: 'Appliance Color',   merge: 'vehicle.interior_color' },
    /\brefrigerator\s*size\b/i         => { label: 'Refrigerator Size', merge: 'vehicle.refrigerator' },
    /\brefrigerator\b/i                => { label: 'Refrigerator',      merge: 'vehicle.refrigerator' },
    /\bgas\s*service\b/i               => { label: 'Gas Service',       merge: 'vehicle.fuel_type' },
    /\bamperage\b/i                    => { label: 'Amperage',           merge: 'vehicle.electrical_service' },
    /\bcustomer\s*name\b/i             => { label: 'Customer Name',     merge: 'deal.customer_name' },
    /\bthermostat\b/i                  => { label: 'Thermostat',        merge: 'vehicle.heating_type' },
    /\bsmoke\s*detect/i                => { label: 'Smoke Detector',    merge: 'vehicle.heating_type' },
    /\bgfci\b/i                        => { label: 'GFCI',              merge: 'vehicle.electrical_service' },
    /\bcircuit\b/i                     => { label: 'Circuit Breaker',   merge: 'vehicle.electrical_service' },
    /\bair\s*condition/i               => { label: 'Air Conditioning',  merge: 'vehicle.central_air' },
  }.freeze

  def map_appliance_fields(page_fields, page_text = [])
    page_fields.map do |f|
      name = f[:name].to_s
      label = resolve_field_label(f, name, page_text)
      merge_field = nil
      auto_fill = false

      # First try matching by field name or resolved label
      APPLIANCE_LABEL_MAP.each do |pattern, info|
        if name.match?(pattern) || label.match?(pattern)
          label = info[:label]
          merge_field = info[:merge]
          auto_fill = true
          break
        end
      end

      # For unnamed/generic widgets, match to nearest left-side text label by Y-position
      if merge_field.nil? && (name.blank? || name.match?(/^(Text|Fill)\s*\d*$/i) || f[:type].nil?)
        nearby = find_nearest_label(f, page_text)
        if nearby.present?
          APPLIANCE_LABEL_MAP.each do |pattern, info|
            if nearby.match?(pattern)
              label = info[:label]
              merge_field = info[:merge]
              auto_fill = true
              break
            end
          end
          label = nearby.strip if merge_field.nil?
        end
      end

      build_mapped_field(f, label: label, type: 'text', group: 'unit',
                         merge_field: merge_field, auto_fill: auto_fill)
    end
  end

  # Page 4: Color Selections (PA-02-26 color sheet)
  def map_color_fields(page_fields, page_text = [])
    # Comprehensive label → merge field mapping from the PA-02-26 color selection sheet
    # Patterns ordered specific-first, broad-last. OCR may produce labels with or
    # without "Color" suffix (e.g., "Interior Trim:" vs "Interior Trim Color").
    # Broad catch-all patterns at the end handle either form.
    color_label_map = {
      # Customer / Notes (specific, checked first)
      /\bcustomer\s*name\b/i              => { label: 'Customer Name',         merge: 'deal.customer_name' },
      /\bnotes\b/i                        => { label: 'Notes',                 merge: 'deal.notes' },

      # Interior specifics (longer patterns first)
      /\binterior\s*trim/i               => { label: 'Interior Trim',         merge: 'vehicle.interior_color' },
      /\binterior\s*door/i               => { label: 'Interior Door',         merge: 'vehicle.interior_color' },
      /\binterior\s*type\b/i             => { label: 'Interior Type',         merge: 'vehicle.interior_color' },
      /\binterior\s*color\b/i            => { label: 'Interior Color',        merge: 'vehicle.interior_color' },
      /\binterior\b/i                    => { label: 'Interior',              merge: 'vehicle.interior_color' },

      # Accent / Tray / Wainscot
      /\baccent\s*wall/i                 => { label: 'Accent Wall',           merge: 'vehicle.interior_color' },
      /\btray.*coffer/i                  => { label: 'Tray/Coffer',           merge: 'vehicle.ceiling_type' },
      /\bwainscot/i                      => { label: 'Wainscot',              merge: 'vehicle.wall_type' },

      # Kitchen sink
      /\bkitchen\s*sink/i               => { label: 'Kitchen Sink',          merge: 'vehicle.interior_color' },

      # Counter tops
      /\bcounter\s*tops?/i              => { label: 'Counter Tops',          merge: 'vehicle.interior_color' },

      # Ceramic / Tile
      /\bceramic\s*tile\s*backsplash/i  => { label: 'Ceramic Tile Backsplash', merge: 'vehicle.interior_color' },
      /\bceramic\s*edge/i               => { label: 'Ceramic Edge',          merge: 'vehicle.interior_color' },
      /\bceramic\s*tile/i               => { label: 'Ceramic Tile',          merge: 'vehicle.flooring_type' },
      /\bmosaic\s*insert/i              => { label: 'Mosaic Insert',         merge: 'vehicle.interior_color' },

      # Cabinets
      /\bcabinet\s*hardware\s*color\b/i => { label: 'Cabinet Hardware Color', merge: 'vehicle.interior_color' },
      /\bcabinet\s*hardware\b/i         => { label: 'Cabinet Hardware',      merge: 'vehicle.interior_color' },
      /\bcabinet\s*color/i              => { label: 'Cabinet Color',         merge: 'vehicle.interior_color' },
      /\bcabinet\s*style/i              => { label: 'Cabinet Style',         merge: 'vehicle.interior_color' },
      /\bcabinet\s*type/i               => { label: 'Cabinet Type',          merge: 'vehicle.interior_color' },
      /\bcabinet\b/i                    => { label: 'Cabinet',               merge: 'vehicle.interior_color' },

      # Flooring
      /\bcarpet\s*color\b/i             => { label: 'Carpet Color',          merge: 'vehicle.flooring_type' },
      /\bcarpet\b/i                     => { label: 'Carpet',                merge: 'vehicle.flooring_type' },
      /\blinoleum\s*color\b/i           => { label: 'Linoleum Color',        merge: 'vehicle.flooring_type' },
      /\blinoleum\b/i                   => { label: 'Linoleum',              merge: 'vehicle.flooring_type' },
      /\bwood\s*laminate\s*color\b/i    => { label: 'Wood Laminate Color',   merge: 'vehicle.flooring_type' },
      /\bwood\s*laminate\b/i            => { label: 'Wood Laminate',         merge: 'vehicle.flooring_type' },
      /\bdecor\b/i                      => { label: 'Decor',                 merge: 'vehicle.flooring_type' },

      # Exterior
      /\bbody\s*color\b/i               => { label: 'Body Color',            merge: 'vehicle.exterior_color' },
      /\bbody\b/i                       => { label: 'Body',                  merge: 'vehicle.exterior_material' },
      /\bshingles?\s*color\b/i          => { label: 'Shingles Color',        merge: 'vehicle.roof_material' },
      /\bshingles?\b/i                  => { label: 'Shingles',              merge: 'vehicle.roof_material' },
      /\btrim\s*color\b/i               => { label: 'Trim Color',            merge: 'vehicle.exterior_color' },
      /\bfacia.*soffit/i                => { label: 'Facia/Soffit',          merge: 'vehicle.exterior_color' },
      /\baccent\s*color\b/i             => { label: 'Accent Color',          merge: 'vehicle.exterior_color' },
      /\bshutter\s*color\b/i            => { label: 'Shutter Color',         merge: 'vehicle.exterior_color' },
      /\broof\s*load\b/i                => { label: 'Roof Load',             merge: 'vehicle.roof_material' },
      /\bexterior\b/i                   => { label: 'Exterior',              merge: 'vehicle.exterior_color' },

      # Floor section header (broad catch-all, last)
      /\bfloor\b/i                      => { label: 'Floor',                 merge: 'vehicle.flooring_type' },
    }

    # ── Build section header index for context-aware matching ──
    # Section headers are OCR labels at x < 35% that match known section patterns.
    # We sort by Y so we can find the nearest section ABOVE any field.
    section_patterns = [
      'Interior', 'Interior Door', 'Interior Trim', 'Accent Wall', 'Wainscot',
      'Kitchen Sink', 'Counter Tops', 'Counter Top',
      'Ceramic Tile Backsplash', 'Ceramic Tile', 'Ceramic Edge', 'Mosaic Insert',
      'Cabinet Color', 'Cabinet',
      'Floor', 'Carpet', 'Linoleum', 'Wood Laminate', 'Decor',
      'Exterior', 'Body', 'Shingles', 'Trim Color', 'Facia', 'Shutter',
      'Tray', 'Coffer'
    ]
    section_headers = page_text.select do |item|
      text = item[:text].to_s.strip
      next false if text.length < 3 || text.length > 40
      section_patterns.any? { |sp| text.match?(/\b#{Regexp.escape(sp)}\b/i) }
    end.sort_by { |item| item[:y].to_f }

    page_fields.map do |f|
      name = f[:name].to_s
      label = resolve_field_label(f, name, page_text)
      merge_field = nil
      auto_fill = false

      # First try matching by field name or resolved label
      color_label_map.each do |pattern, info|
        if name.match?(pattern) || label.match?(pattern)
          label = info[:label]
          merge_field = info[:merge]
          auto_fill = true
          break
        end
      end

      # For unnamed/generic widgets, use nearest label + section context
      if merge_field.nil? && (name.blank? || name.match?(/^(Text|Fill)\s*\d*$/i) || f[:type].nil?)
        nearby = find_nearest_label(f, page_text)
        if nearby.present?
          # Direct match on nearest label
          color_label_map.each do |pattern, info|
            if nearby.match?(pattern)
              label = info[:label]
              merge_field = info[:merge]
              auto_fill = true
              break
            end
          end

          # If no direct match, try section context — but ONLY for standalone fields.
          # Room-specific sub-entries (Kitchen, Master Bath, Guest Bath, etc.) are
          # individual color choices that can't be auto-filled from one DB column.
          if merge_field.nil?
            is_room_sub_entry = nearby.match?(/\b(kitchen|master\s*bath|guest\s*bath|3rd\s*bath|utility\s*room|master\s*bed)\b/i)

            unless is_room_sub_entry
              fy = f[:y].to_f
              section_above = section_headers.select { |h| h[:y].to_f < fy }
                                            .last  # Last one before this Y = nearest above
              if section_above
                combined = "#{section_above[:text].strip} #{nearby.strip}"
                color_label_map.each do |pattern, info|
                  if combined.match?(pattern)
                    label = info[:label]
                    merge_field = info[:merge]
                    auto_fill = true
                    break
                  end
                end
              end

              # Still no match? Try section header alone
              if merge_field.nil? && section_above
                color_label_map.each do |pattern, info|
                  if section_above[:text].strip.match?(pattern)
                    label = "#{section_above[:text].strip} - #{nearby.strip}"
                    merge_field = info[:merge]
                    auto_fill = true
                    break
                  end
                end
              end
            end
          end

          label = nearby.strip if merge_field.nil?
        end
      end

      build_mapped_field(f, label: label, type: 'text', group: 'general',
                         merge_field: merge_field, auto_fill: auto_fill)
    end
  end

  # Pages 5-12, 16: Disclosure/signature pages
  def map_signature_page_fields(page_fields, page_num, page_text = [])
    page_fields.map do |f|
      name = f[:name].to_s
      match_name = f[:clean_name] || name
      label = resolve_field_label(f, match_name, page_text)
      scan_type = ACROFORM_TYPE_MAP[f[:type]] || 'text'
      merge_field = nil
      auto_fill = false
      group = 'signatures'

      # Signature_es_ fields (e.g. "Signature1_es_:signer:signature") — DocuSign-style
      if name.match?(/Signature\d*_es_/i)
        scan_type = 'signature'
        auto_fill = true
        if f[:y] > 85  # Bottom of page = signature block
          if name.match?(/[13579]_es_/) # Odd numbered = first signer row (rep + buyer 1)
            merge_field = f[:x] < 50 ? 'signer.role.dealer_rep' : 'signer.role.buyer_1'
            label = f[:x] < 50 ? 'Dealer Rep Signature' : 'Buyer 1 Signature'
          else # Even numbered = second signer row (manager + buyer 2)
            merge_field = f[:x] < 50 ? 'signer.role.dealer_manager' : 'signer.role.buyer_2'
            label = f[:x] < 50 ? 'Manager Signature' : 'Buyer 2 Signature'
          end
        else
          merge_field = 'signer.role.buyer_1'
          label = 'Buyer 1 Signature'
        end
      # Native signature type fields
      elsif f[:type] == 'signature' || scan_type == 'signature'
        scan_type = 'signature'
        auto_fill = true
        if f[:x] < 40
          if name.match?(/manager/i) || label.match?(/manager/i)
            label = 'Manager Signature'
            merge_field = 'signer.role.dealer_manager'
          else
            label = 'Dealer Rep Signature'
            merge_field = 'signer.role.dealer_rep'
          end
        elsif f[:x] < 70
          label = 'Buyer 1 Signature'
          merge_field = 'signer.role.buyer_1'
        else
          label = 'Buyer 2 Signature'
          merge_field = 'signer.role.buyer_2'
        end
      # Date fields — MUST check BEFORE initials (Date_N are small but are dates, not initials)
      elsif match_name.match?(/\bdate\b/i) && match_name.split(/\s+/).length <= 3 && !match_name.match?(/update|mandate/i)
        scan_type = 'date'
        label = 'Signing Date'
        merge_field = 'date.today'
        auto_fill = true
      # BUYER 1_N / BUYER 2_N fields on signature pages = signer signature placeholders
      elsif name.match?(/\bBUYER\s*1\b/i)
        scan_type = 'signature'
        label = 'Buyer 1 Signature'
        merge_field = 'signer.role.buyer_1'
        auto_fill = true
      elsif name.match?(/\bBUYER\s*2\b/i)
        scan_type = 'signature'
        label = 'Buyer 2 Signature'
        merge_field = 'signer.role.buyer_2'
        auto_fill = true
      # Dealer Rep / Manager fields
      elsif name.match?(/Representative/i)
        scan_type = 'signature'
        label = 'Dealer Rep Signature'
        merge_field = 'signer.role.dealer_rep'
        auto_fill = true
      elsif name.match?(/Manager/i)
        scan_type = 'signature'
        label = 'Manager Signature'
        merge_field = 'signer.role.dealer_manager'
        auto_fill = true
      # Initials (tightened width check: real initials are <8% wide, not 11%+)
      # Just classify as initials — universal pair_initials_by_position assigns buyer_1 vs buyer_2
      elsif name.match?(/initial/i) || label.match?(/initial/i) || (f[:width] < 8 && f[:height] < 4)
        scan_type = 'initials'
        auto_fill = true
        label = 'Buyer 1 Initials'  # default; universal pairing will fix
        merge_field = 'signer.role.buyer_1_initials'
      elsif name.match?(/\b(day|month|year)\b/i) && name.split(/\s+/).length <= 3
        scan_type = 'text'
        merge_field = nil
        auto_fill = false
      elsif f[:type] == 'checkbox'
        scan_type = 'checkbox'
        group = 'terms'
      else
        group = 'general'
      end

      build_mapped_field(f, label: label, type: scan_type, group: group,
                         merge_field: merge_field, auto_fill: auto_fill)
    end
  end

  # Page 13: Tires & Axles Bill of Sale
  def map_tires_axles_fields(page_fields, page_text = [])
    page_fields.map do |f|
      name = f[:name].to_s
      label = resolve_field_label(f, name, page_text)
      scan_type = ACROFORM_TYPE_MAP[f[:type]] || 'text'
      merge_field = nil
      auto_fill = false

      if name.match?(/phone/i) || label.match?(/phone/i)
        merge_field = 'contact.phone'
        auto_fill = true
      elsif name.match?(/cell/i) || label.match?(/cell/i)
        merge_field = 'contact.cell_phone'
        auto_fill = true
      elsif name.match?(/email/i) || label.match?(/email/i)
        merge_field = 'contact.email'
        auto_fill = true
      elsif f[:type] == 'signature'
        scan_type = 'signature'
        merge_field = f[:x] < 50 ? 'signer.role.dealer_rep' : 'signer.role.buyer_1'
        auto_fill = true
      elsif name.match?(/date/i) || label.match?(/date/i)
        scan_type = 'date'
        merge_field = 'date.today'
        auto_fill = true
      end

      group = merge_field&.start_with?('signer') ? 'signatures' : 'general'
      build_mapped_field(f, label: label, type: scan_type, group: group,
                         merge_field: merge_field, auto_fill: auto_fill)
    end
  end

  # Page 14: Shipping Directions & Map
  def map_shipping_fields(page_fields, page_text = [])
    shipping_patterns = {
      /address|street/i   => { label: 'Shipping Address', merge: 'property.street',   auto: true },
      /city/i             => { label: 'City',             merge: 'property.city',     auto: true },
      /state/i            => { label: 'State',            merge: 'property.state',    auto: true },
      /zip/i              => { label: 'Zip',              merge: 'property.zip',      auto: true },
      /contact\s*name/i   => { label: 'Contact Name',     merge: 'contact.full_name', auto: true },
      /daytime\s*phone/i  => { label: 'Daytime Phone',    merge: 'contact.phone',     auto: true },
      /evening\s*phone/i  => { label: 'Evening Phone',    merge: 'contact.phone',     auto: true },
      /cell/i             => { label: 'Cell Phone',        merge: 'contact.cell_phone', auto: true },
      /phone/i            => { label: 'Phone',             merge: 'contact.phone',     auto: true },
      /direction/i        => { label: 'Directions',        merge: nil,                 auto: false },
    }

    page_fields.map do |f|
      name = f[:name].to_s
      label = resolve_field_label(f, name, page_text)
      merge_field = nil
      auto_fill = false

      shipping_patterns.each do |pattern, info|
        if name.match?(pattern) || label.match?(pattern)
          label = info[:label]
          merge_field = info[:merge]
          auto_fill = info[:auto]
          break
        end
      end

      if f[:type] == 'signature'
        build_mapped_field(f, label: 'Signature', type: 'signature', group: 'signatures',
                           merge_field: 'signer.role.buyer_1', auto_fill: true)
      else
        build_mapped_field(f, label: label, type: 'text', group: 'delivery',
                           merge_field: merge_field, auto_fill: auto_fill)
      end
    end
  end

  # Page 15: Title Information
  def map_title_info_fields(page_fields, page_text = [])
    title_patterns = {
      /owner\s*1\s*name|buyer\s*1/i  => { label: 'Owner 1 Name',       merge: 'contact.full_name' },
      /owner\s*2\s*name|buyer\s*2/i  => { label: 'Owner 2 Name',       merge: 'contact2.full_name' },
      /driver.*license.*1|dl\s*1/i   => { label: 'Owner 1 DL Number',  merge: 'contact.drivers_license_number' },
      /driver.*license.*2|dl\s*2/i   => { label: 'Owner 2 DL Number',  merge: 'contact2.drivers_license_number' },
      /dl\s*state.*1/i               => { label: 'Owner 1 DL State',   merge: 'contact.drivers_license_state' },
      /dl\s*state.*2/i               => { label: 'Owner 2 DL State',   merge: 'contact2.drivers_license_state' },
      /dob.*1|date.*birth.*1/i       => { label: 'Owner 1 DOB',        merge: 'contact.date_of_birth' },
      /dob.*2|date.*birth.*2/i       => { label: 'Owner 2 DOB',        merge: 'contact2.date_of_birth' },
      /ein.*1/i                      => { label: 'Owner 1 EIN',        merge: 'contact.ein' },
      /ein.*2/i                      => { label: 'Owner 2 EIN',        merge: 'contact2.ein' },
      /lien\s*holder/i               => { label: 'Lien Holder',        merge: 'lien.holder_name' },
      /lien\s*address|lienholder.*addr/i => { label: 'Lien Address',   merge: 'lien.holder_address' },
      /amount\s*of\s*lien/i          => { label: 'Amount of Lien',     merge: 'lien.amount' },
      /date\s*of\s*lien/i            => { label: 'Date of Lien',       merge: 'lien.date' },
      /mail\s*mso|mso.*mail/i        => { label: 'Mail MSO/Title To',  merge: 'lien.mso_mail_to' },
      /mso.*city/i                   => { label: 'MSO City',           merge: 'lien.mso_city' },
      /mso.*state/i                  => { label: 'MSO State',          merge: 'lien.mso_state' },
      /mso.*zip/i                    => { label: 'MSO Zip',            merge: 'lien.mso_zip' },
    }

    # Sort by y to use position-based owner 1 vs owner 2 fallback
    sorted = page_fields.sort_by { |f| [f[:y], f[:x]] }
    owner1_y_max = sorted.length > 0 ? sorted[sorted.length / 2][:y] : 50

    sorted.map do |f|
      name = f[:name].to_s
      label = resolve_field_label(f, name, page_text)
      merge_field = nil
      auto_fill = false

      title_patterns.each do |pattern, info|
        if name.match?(pattern) || label.match?(pattern)
          label = info[:label]
          merge_field = info[:merge]
          auto_fill = true
          break
        end
      end

      # Position-based fallback for generic driver/dob/ein fields
      unless merge_field
        if name.match?(/driver|license|dl/i)
          prefix = f[:y] < owner1_y_max ? 'contact' : 'contact2'
          label = f[:y] < owner1_y_max ? 'Owner 1 DL Number' : 'Owner 2 DL Number'
          merge_field = "#{prefix}.drivers_license_number"
          auto_fill = true
        elsif name.match?(/dob|birth/i)
          prefix = f[:y] < owner1_y_max ? 'contact' : 'contact2'
          label = f[:y] < owner1_y_max ? 'Owner 1 DOB' : 'Owner 2 DOB'
          merge_field = "#{prefix}.date_of_birth"
          auto_fill = true
        elsif name.match?(/ein/i)
          prefix = f[:y] < owner1_y_max ? 'contact' : 'contact2'
          label = f[:y] < owner1_y_max ? 'Owner 1 EIN' : 'Owner 2 EIN'
          merge_field = "#{prefix}.ein"
          auto_fill = true
        end
      end

      group = merge_field&.start_with?('lien') ? 'general' : 'buyer'
      scan_type = f[:type] == 'signature' ? 'signature' : 'text'

      build_mapped_field(f, label: label, type: scan_type, group: group,
                         merge_field: merge_field, auto_fill: auto_fill)
    end
  end

  # Fallback: generic field mapping for unrecognized pages
  def map_generic_fields(page_fields, page_text = [])
    page_fields.map do |f|
      label = resolve_field_label(f, f[:name].to_s, page_text)
      scan_type = ACROFORM_TYPE_MAP[f[:type]] || 'text'
      group = infer_group_from_label(label, f[:page])
      build_mapped_field(f, label: label, type: scan_type, group: group,
                         merge_field: nil, auto_fill: false)
    end
  end

  # Filter out AcroForm fields that overlap heavily with printed body text.
  # These are structural/decorative fields in the PDF, not actual input fields.
  # An input field should be on BLANK space, not on top of printed paragraphs.
  def filter_body_text_overlap_fields(acroform_fields, raw_text_map, garbled_pages = [])
    return acroform_fields if raw_text_map.empty?

    acroform_fields.select do |field|
      page = field[:page]
      next true if garbled_pages.include?(page)  # Skip garbled-text pages (encoding noise, not real paragraphs)
      page_text = raw_text_map[page] || []
      next true if page_text.empty?

      fx = field[:x].to_f
      fy = field[:y].to_f
      fw = field[:width].to_f
      fh = field[:height].to_f
      field_area = fw * fh

      # Count ALL text items (even garbled) whose position falls inside this field
      # Real input fields have 0-1 text items inside them (maybe a placeholder)
      # Fields on paragraph text have 3+ items inside them
      overlapping_count = page_text.count do |item|
        ix = item[:x].to_f
        iy = item[:y].to_f
        # Text item origin is inside field bounds (with small tolerance)
        ix >= fx - 1 && ix <= fx + fw + 1 && iy >= fy - 0.5 && iy <= fy + fh + 0.5
      end

      # Rule 1: Large fields (area > 150) with ANY text inside = structural/decorative
      if field_area > 150 && overlapping_count >= 2
        Rails.logger.debug "[AcroForm] REJECTED '#{field[:name]}' p#{page} — large field (area=#{field_area.round(0)}) with #{overlapping_count} text items inside"
        next false
      end

      # Rule 2: Medium+ fields with 3+ text items inside = sitting on paragraph
      if overlapping_count >= 3
        Rails.logger.debug "[AcroForm] REJECTED '#{field[:name]}' p#{page} — #{overlapping_count} text items inside (x:#{fx.round(1)} y:#{fy.round(1)} w:#{fw.round(1)} h:#{fh.round(1)})"
        next false
      end

      # Rule 3: Very wide fields (width > 40%) with 2+ text items = likely a text block area
      if fw > 40 && overlapping_count >= 2
        Rails.logger.debug "[AcroForm] REJECTED '#{field[:name]}' p#{page} — wide field (w=#{fw.round(1)}%) with #{overlapping_count} text items"
        next false
      end

      # Rule 4: Very tall fields (height > 5%) with 2+ text items = multi-line text block
      if fh > 5 && overlapping_count >= 2
        Rails.logger.debug "[AcroForm] REJECTED '#{field[:name]}' p#{page} — tall field (h=#{fh.round(1)}%) with #{overlapping_count} text items"
        next false
      end

      true
    end
  rescue => e
    Rails.logger.warn "[AcroForm] Body text overlap filter failed: #{e.message}"
    acroform_fields
  end

  # ─── Label Resolution Helpers ──────────────────────────────────────────────

  # Resolve the best label for a field: try field name first, fall back to nearby printed text
  def resolve_field_label(field, name, page_text)
    label = infer_label_from_name(name)
    is_generic = label.match?(/^(Text|Fill|Check\s*Box|Signature)\s*\d*$/i) || label == name.strip

    if is_generic && page_text.any?
      nearby = find_nearest_label(field, page_text)
      if nearby.present?
        label = nearby.strip
        ACROFORM_LABEL_MAP.each do |pattern, mapped_label|
          if nearby.match?(pattern)
            label = mapped_label
            break
          end
        end
      end
    end

    label
  end

  # Filter PDF text items to only include clean, human-readable labels
  # Removes encoding artifacts (garbled text), body paragraphs, and noise
  def sanitize_text_for_labeling(text_items)
    return [] if text_items.blank?

    # Known form label words — if text contains any of these, it's a real label
    label_words = %w[
      buyer seller date deal address mailing delivery city state zip phone cell
      email salesperson make model year bedroom bath den serial number vin
      new used floor hitch size approx manufacturer certificate tag
      retail price factory direct savings discount sub total freight setup
      extended service document fee tax payment additional unpaid balance
      signature signed initial customer name driver license birth ein dob
      lien holder amount mail title county space park mobile home
      completion month notation remark verbal promise certified
      addendum upgrade color interior exterior carpet cabinet shingle trim
      fireplace furnace washer dryer range refrigerator dishwasher
      microwave heater ductwork amperage appliance ac ready
      property direction shipping contact daytime evening
      warranty arbitration tire axle verification hud
      or and check one applicable signer
      no amt mi apt ss co type style hardware body roof
    ]

    # Body text phrases — always reject these even if short
    body_phrases = [
      /buyer\s+understands/i, /buyer\s+agrees/i, /buyer\s+is\s+responsible/i,
      /factory\s+direct\s+homes/i, /in\s+the\s+event/i, /understands\s+that/i,
      /responsible\s+for/i, /agrees\s+that/i, /unless\s+otherwise/i,
      /subject\s+to/i, /please\s+read/i, /by\s+signing/i, /acknowledge/i,
      /this\s+agreement/i, /notice\s+of/i, /all\s+sales/i,
    ]

    kept = 0
    rejected_samples = []

    result = text_items.select do |item|
      text = item[:text].to_s.gsub(/\x00/, '').strip
      next false if text.blank?
      next false if text.length < 2
      next false if text.length > 35
      next false if text.match?(/^\d+$/)
      next false if text.match?(/^[xX_\-\.=\s]+$/)
      next false if text.match?(/^Page\s+\d/i)

      # Must be printable ASCII
      ascii_count = text.chars.count { |c| c.ord.between?(32, 126) }
      next false if ascii_count.to_f / text.length < 0.9

      # Reject encoding garbage
      next false if text.match?(/^[A-Z0-9]{5,}$/) && !text.include?(' ')
      next false if text.match?(/^[A-Za-z0-9]{6,}$/) && !text.include?(' ') && text.match?(/\d/) && text.match?(/[A-Z]/) && text.match?(/[a-z]/)
      next false if text.match?(/\+[A-Z][a-z]/i)
      next false if text.match?(/[^\x20-\x7E]/)

      # Reject body text phrases
      if body_phrases.any? { |phrase| text.match?(phrase) }
        rejected_samples << text if rejected_samples.length < 5
        next false
      end

      # Reject mid-sentence body text (starts lowercase, 3+ words)
      if text.match?(/^[a-z]/) && text.split(/\s+/).length > 2
        rejected_samples << text if rejected_samples.length < 5
        next false
      end

      text_lower = text.downcase
      word_count = text.split(/\s+/).length

      # TIER 1: Contains a known label word — strong accept
      has_label_word = label_words.any? { |word| text_lower.include?(word) }
      if has_label_word
        kept += 1
        next true
      end

      # TIER 2: Short label-like text (1-3 words, starts with capital, not all-caps section header)
      is_short_clean = word_count <= 3 &&
                       text.match?(/^[A-Z]/) &&
                       !text.match?(/^[A-Z\s&]{8,}$/) && # Reject all-caps section headers
                       text.length <= 20
      if is_short_clean
        kept += 1
        next true
      end

      # TIER 3: Has a colon (label: pattern) — common in forms
      if text.include?(':') && word_count <= 4
        kept += 1
        next true
      end

      # Not accepted — log for debugging
      rejected_samples << text if rejected_samples.length < 10
      false
    end.map do |item|
      item.merge(text: item[:text].to_s.gsub(/\x00/, '').strip)
    end

    if rejected_samples.any?
      Rails.logger.debug "[AcroForm] Sanitizer rejected samples: #{rejected_samples.first(5).map { |s| "'#{s}'" }.join(', ')}"
    end

    result
  end

  # Find the nearest printed text label for an AcroForm field
  def find_nearest_label(field, page_text_items)
    return nil if page_text_items.blank?

    fx = field[:x].to_f
    fy = field[:y].to_f

    best_label = nil
    best_score = Float::INFINITY

    page_text_items.each do |item|
      text = item[:text].to_s.gsub(/\x00/, '').strip
      # STRICT label filtering — labels are short, clean text
      next if text.length < 2
      next if text.length > 30            # Labels are short (reduced from 40)
      next if text.split(/\s+/).length > 5 # Max 5 words
      next if text.match?(/^\d+$/)
      next if text.match?(/^[xX_\-\.=\s]+$/)
      next if text.match?(/^Page\s+\d/i)
      next if text.match?(/^[a-z]/) && text.split(/\s+/).length > 2  # Mid-sentence body text

      # Reject body paragraph phrases — these are NOT labels
      next if text.match?(/\b(buyer\s+understands|buyer\s+agrees|factory\s+direct|in\s+the\s+event|understands\s+that|responsible\s+for|unless\s+otherwise|subject\s+to|please\s+read|by\s+signing|acknowledge|this\s+agreement|notice\s+of|all\s+sales)\b/i)

      # Skip encoding garbage (safety net — should be filtered by sanitizer)
      ascii_count = text.chars.count { |c| c.ord.between?(32, 126) }
      next if ascii_count.to_f / text.length < 0.9
      next if text.match?(/^[A-Z0-9]{5,}$/) && !text.include?(' ')
      next if text.match?(/\+[A-Z][a-z]/i)  # Font name artifacts like 'AAAAAB+Arial'

      ix = item[:x].to_f
      iy = item[:y].to_f
      iw = item[:width] || (text.length * 0.55)  # Use real width if available

      y_diff = (iy - fy).abs
      score = nil

      # Case 1: Label to the LEFT on same row (within 2% y tolerance) — strongest signal
      if y_diff < 2.0 && ix < fx && (ix + iw) <= fx + 2
        distance = (fx - ix - iw).abs + (y_diff * 2)
        score = distance
        score -= 5 if (fx - ix - iw).abs < 3  # Bonus: label ends right before field
      # Case 2: Label ABOVE field (within 5% y, 10% x overlap)
      elsif iy < fy && (fy - iy).between?(0.5, 5.0) && (ix - fx).abs < 10
        distance = (fy - iy) + ((ix - fx).abs * 0.5)
        score = distance + 10
      # Case 3: Label overlapping field area
      elsif y_diff < 1.5 && (ix - fx).abs < 3
        score = y_diff + (ix - fx).abs + 15
      end

      if score && score < best_score
        best_score = score
        best_label = text
      end
    end

    # Final safety: reject if result is still garbage
    if best_label
      return nil if best_label.match?(/^[A-Z0-9]{5,}$/) && !best_label.include?(' ')
      return nil if best_label.length > 30
      return nil if best_label.split(/\s+/).length > 5
      return nil if best_label.chars.count { |c| c.ord.between?(32, 126) }.to_f / best_label.length < 0.9
    end

    best_label&.gsub(/\x00/, '')
  end

  # ─── Field Builder Helpers ───────────────────────────────────────────────────

  def build_mapped_field(raw, label:, type:, group:, merge_field: nil, auto_fill: false)
    label = label.to_s.gsub(/\x00/, '').strip

    # Safety net: if label is garbled, too long, or encoding artifact — fall back to cleaned field name
    is_garbled = label.blank? ||
                 label.length > 35 ||
                 label.split(/\s+/).length > 6 ||
                 (label.match?(/^[A-Z0-9]{5,}$/) && !label.include?(' ')) ||
                 (label.match?(/^[A-Za-z0-9]{6,}$/) && !label.include?(' ') && label.match?(/\d/) && label.match?(/[A-Z]/)) ||
                 label.match?(/\+[A-Z][a-z]/i) ||
                 label.chars.count { |c| c.ord.between?(32, 126) }.to_f / [label.length, 1].max < 0.85

    if is_garbled
      raw_name = raw[:name].to_s.gsub(/\x00/, '').strip
      label = raw_name.gsub(/([a-z])(\d)/, '\1 \2').gsub(/_/, ' ').gsub(/([a-z])([A-Z])/, '\1 \2').strip.split.map(&:capitalize).join(' ')
      label = 'Field' if label.blank?
    end

    # For unmapped fields, add clear positional context to help users identify them
    if merge_field.nil? && !auto_fill
      if label.match?(/^(Text|Fill|Check\s*Box|Signature)\s*\d*$/i) || label == 'Field' || label == 'Unknown'
        page_num = raw[:page] || 1
        field_type_hint = case type
                          when 'signature' then 'Sig'
                          when 'checkbox' then 'Check'
                          when 'initials' then 'Init'
                          else 'Field'
                          end
        label = "P#{page_num} #{field_type_hint} - #{raw[:name]}"
      end
    end

    key = label.parameterize(separator: '_').gsub(/\x00/, '').first(30)
    key = "cf_#{key}" unless key.start_with?("cf_")

    {
      key: key,
      label: label,
      type: type,
      group: group,
      page: raw[:page],
      x: [[raw[:x], 1].max, 95].min.round(1),
      y: [[raw[:y], 1].max, 95].min.round(1),
      width: [[raw[:width], 2].max, 50].min.round(1),
      height: clamp_height(type, raw[:height]),
      required: (raw[:flags].to_i & 2) != 0,
      confidence: 0.95,
      source: 'acroform',
      original_field_name: raw[:name],
      merge_field: merge_field,
      auto_fill: auto_fill,
    }
  end

  def group_fields_into_rows(fields, y_tolerance: 1.5)
    rows = []
    used = Set.new
    sorted = fields.sort_by { |f| f[:y] }

    sorted.each_with_index do |field, idx|
      next if used.include?(idx)

      row = [field]
      used.add(idx)

      sorted.each_with_index do |other, other_idx|
        next if used.include?(other_idx)
        if (other[:y] - field[:y]).abs < y_tolerance
          row << other
          used.add(other_idx)
        end
      end

      rows << row
    end

    rows
  end

  def infer_label_from_name(field_name)
    return 'Unknown' if field_name.blank?

    name = field_name.to_s.gsub(/\x00/, '').strip

    ACROFORM_LABEL_MAP.each do |pattern, label|
      return label if name.match?(pattern)
    end

    # Clean up raw name: 'Text1' -> 'Text 1', 'BUYER_2_city' -> 'Buyer 2 City'
    cleaned = name.gsub(/([a-z])(\d)/, '\1 \2')
                  .gsub(/_/, ' ')
                  .gsub(/([a-z])([A-Z])/, '\1 \2')
                  .strip
                  .split.map(&:capitalize).join(' ')

    cleaned.presence || 'Unknown'
  end

  def infer_group_from_label(label, page)
    lower = label.downcase
    if lower.match?(/buyer|name|driver|dob|license|ein/)
      'buyer'
    elsif lower.match?(/address|city|state|zip|phone|cell|email/)
      'delivery'
    elsif lower.match?(/manufacturer|model|year|serial|vin|bedroom|bath|den|floor|hitch|new|used/)
      'unit'
    elsif lower.match?(/price|cost|total|payment|balance|deposit|tax|fee|amount|sub/)
      'pricing'
    elsif lower.match?(/signature/)
      'signatures'
    elsif lower.match?(/initial/)
      'signatures'
    else
      'general'
    end
  end

  def sanitize_for_json(obj)
    case obj
    when String then obj.gsub(/\x00/, '')
    when Hash then obj.transform_values { |v| sanitize_for_json(v) }
    when Array then obj.map { |v| sanitize_for_json(v) }
    else obj
    end
  end
end
