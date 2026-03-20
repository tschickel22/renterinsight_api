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

    page_classifications = classify_pages(fields, total_pages)
    Rails.logger.info "[VisionScan] Classified #{page_classifications.length} pages: #{page_classifications.map { |p| "#{p[:page]}=#{p[:type]}" }.join(', ')}"

    {
      fields: fields,
      pages_scanned: pages_to_scan,
      total_pages: total_pages,
      page_classifications: page_classifications,
    }
  end

  # Smart Scan: Compare empty template PDF against a filled example PDF
  # Returns enhanced fields with example_value, inferred_type, formula, is_repeated
  def smart_scan(empty_pdf_url, filled_pdf_url, max_pages: MAX_PAGES)
    raise ScanError, "No empty PDF URL provided" if empty_pdf_url.blank?
    raise ScanError, "No filled PDF URL provided" if filled_pdf_url.blank?
    @scan_mode = :smart

    Rails.logger.info "[SmartScan] Starting comparison scan"
    Rails.logger.info "[SmartScan]   Empty:  #{empty_pdf_url.truncate(80)}"
    Rails.logger.info "[SmartScan]   Filled: #{filled_pdf_url.truncate(80)}"

    empty_data = download_pdf(empty_pdf_url)
    filled_data = download_pdf(filled_pdf_url)

    [empty_data, filled_data].each_with_index do |data, i|
      label = i == 0 ? 'Empty' : 'Filled'
      if data.bytesize > PDF_MAX_SIZE
        raise ScanError, "#{label} PDF is too large (#{(data.bytesize / 1_000_000.0).round(1)}MB). Maximum is 25MB."
      end
    end

    # Extract text positions from both
    empty_text_map = extract_text_with_positions(empty_data)
    filled_text_map = extract_text_with_positions(filled_data)
    total_pages = [empty_text_map.keys.max || 1, filled_text_map.keys.max || 1].max
    pages_to_scan = [max_pages, total_pages].min

    Rails.logger.info "[SmartScan] Empty: #{empty_text_map.values.sum(&:length)} text items, Filled: #{filled_text_map.values.sum(&:length)} text items, #{total_pages} pages"

    empty_b64 = Base64.strict_encode64(empty_data)
    filled_b64 = Base64.strict_encode64(filled_data)

    fields = call_claude_smart_scan(empty_b64, filled_b64, empty_text_map, filled_text_map, pages_to_scan)
    Rails.logger.info "[SmartScan] Detected #{fields.length} fields with example values"

    page_classifications = classify_pages(fields, total_pages)

    # Detect repeated fields (same example_value on multiple pages)
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
      - For INITIALS patterns like "x____ x____" or "X______ X______" or "Initials Initials": these are TWO separate initials fields side by side (one per buyer/signer). Create TWO initials fields — one for each "x____" block. The first one is for Buyer 1/Signer 1, the second for Buyer 2/Signer 2. Use type "initials" with width ~6, height ~3.
      - For company representative/manager signature lines like "By ___ Factory Direct Homes Center Representative" or "Factory Direct Homes Center MANAGER": these are counter-signer signature fields. Use type "signature" with group "signatures" and label them clearly (e.g. "Company Rep signature", "Manager signature").
      - For stacked table fields (Manufacturer, Model, Serial No. etc.): each field should be at the SAME x position but DIFFERENT y positions, matching the rows in the table.
      - NEVER stack multiple fields at the same x,y — each field must have a UNIQUE y position.

      For each field provide:
      - key: unique snake_case (e.g. "buyer_name")
      - label: exact label text
      - type: text|currency|number|percentage|date|checkbox|signature|initials
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
      - Values like "33" next to "R-VALUE" -> number
      - Checked boxes (filled checkbox, X mark, checkmark) -> checkbox
      - Signature lines with names -> signature
      - Everything else -> text

      FORMULA DETECTION:
      - If SUB-TOTAL = BASE PRICE + OPTIONAL EQUIPMENT, output formula: "=base_price_of_unit+optional_equipment"
      - If CASH PURCHASE PRICE = SUB-TOTAL + SALES TAX, output formula: "=sub_total+sales_tax"
      - If NET ALLOWANCE = TRADE_IN_ALLOWANCE - LESS_BAL_DUE, output formula: "=trade_in_allowance-less_bal_due"
      - If LESS TOTAL CREDITS = DOWN PAYMENT + CASH AS AGREED + NET ALLOWANCE, output formula accordingly
      - Only include formula if you are confident the math checks out with the actual values

      POSITIONING RULES (same as standard scan):
      - For "Label: ________" patterns: INPUT starts AFTER the label text
      - For table cells: INPUT is in the value column, not the label column
      - Checkboxes: width/height about 2.5
      - For INITIALS patterns like "x____ x____" or "X______ X______": these are TWO separate initials fields (one per signer). Use type "initials" with width ~6, height ~3.
      - For company rep/manager signature lines ("By ___ Representative", "By ___ MANAGER"): counter-signer signatures. Use type "signature" with group "signatures".
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
      - inferred_type: the type you inferred from the example value (same options as type)
      - formula: calculation formula if detected (e.g. "=base_price+optional_equipment"), or null

      CRITICAL: Output ONLY a JSON array. No explanation. Start with [ end with ].

      [
        {"key":"buyer_name","label":"BUYER(S)","type":"text","group":"buyer","page":1,"x":15,"y":12,"width":35,"height":2.8,"required":true,"example_value":"Faith E Locy and Luke Wagner","inferred_type":"text","formula":null},
        {"key":"base_price_of_unit","label":"BASE PRICE OF UNIT","type":"currency","group":"pricing","page":1,"x":85,"y":38,"width":12,"height":2.8,"required":true,"example_value":"177,166.00","inferred_type":"currency","formula":null},
        {"key":"sub_total","label":"SUB-TOTAL","type":"currency","group":"pricing","page":1,"x":85,"y":44,"width":12,"height":2.8,"required":true,"example_value":"271,166.00","inferred_type":"currency","formula":"=base_price_of_unit+optional_equipment"}
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
              source: { type: "base64", media_type: "application/pdf", data: empty_b64 },
            },
            {
              type: "document",
              source: { type: "base64", media_type: "application/pdf", data: filled_b64 },
            },
            { type: "text", text: prompt },
          ],
        },
      ],
    }

    uri = URI(CLAUDE_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 180  # 3 min - two PDFs take longer
    http.open_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["x-api-key"] = @api_key
    request["anthropic-version"] = "2023-06-01"
    request.body = body.to_json

    Rails.logger.info "[SmartScan] Sending 2 PDFs + position data to Claude (#{(empty_b64.length + filled_b64.length) / 1024}KB total)"

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

  # Parse smart scan response - same as standard but preserves extra fields
  def parse_smart_response(text)
    fields = parse_response(text)

    # Re-parse the raw JSON to get example_value, inferred_type, formula
    # parse_response strips these, so we extract them from the raw text
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
      field[:is_repeated] = false  # Will be set by smart_scan caller
    end

    fields
  end

  # Extract raw JSON array from response text (before normalize_field strips extra keys)
  def extract_raw_json_fields(text)
    json_str = text.strip
    json_str = json_str.gsub(/```json?\s*/i, '').gsub(/```/, '').strip if json_str.include?('```')
    json_str = $1 if !json_str.start_with?('[') && json_str =~ /(\[\s*\{.*\}\s*\])/m
    return nil unless json_str.start_with?('[')
    JSON.parse(json_str) rescue nil
  end

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
    type = "text" unless %w[text currency number percentage date select checkbox signature initials].include?(type)

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

  # ─── Page Classification ───────────────────────────────────────────────────────

  def classify_pages(fields, total_pages)
    # Build per-page field type sets
    page_data = {}
    fields.each do |f|
      p = f[:page] || 1
      page_data[p] ||= { signatures: 0, initials: 0, checkboxes: 0, data_fields: 0, labels: [] }
      case f[:type]
      when 'signature'
        page_data[p][:signatures] += 1
      when 'initials'
        page_data[p][:initials] += 1
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
                    'signature_page' # Pages with no detected fields are likely disclosure/signature pages
                  end

      # Generate a title from first few field labels or fallback
      title = if info[:labels].any?
                first_label = info[:labels].first.to_s
                if first_label.length > 40
                  first_label[0..37] + '...'
                else
                  first_label
                end
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
