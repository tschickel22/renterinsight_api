# frozen_string_literal: true

require 'prawn'
require 'prawn/table'
require 'net/http'

class ProjectPdfGenerator
  SECTIONS_ALL = %w[overview phases logs photos budget].freeze

  def initialize(project, sections: nil, company: nil)
    @project = project
    @company = company || project.company
    @sections = (sections || SECTIONS_ALL).map(&:to_s) & SECTIONS_ALL
  end

  def generate
    brand = resolve_branding
    accent = brand[:accent]

    pdf = Prawn::Document.new(page_size: 'LETTER', margin: [50, 50, 80, 50])

    add_header(pdf, brand)
    pdf.move_down 20

    add_project_overview(pdf, accent) if @sections.include?('overview')

    if @sections.include?('phases')
      add_phases_section(pdf, accent,
        include_logs: @sections.include?('logs'),
        include_photos: @sections.include?('photos'))
    end

    add_budget_section(pdf, accent) if @sections.include?('budget')

    add_footer(pdf, brand)

    pdf.render
  end

  private

  # ── BRANDING (Location → Company → Platform waterfall) ──
  def resolve_branding
    branding = {}

    # 1. Try Location branding first (if project has a location)
    if @project.location_id.present?
      location_branding = Setting.get('Location', @project.location_id, 'branding', {}) rescue {}
      branding = location_branding if location_branding.is_a?(Hash) && location_branding.values.any?(&:present?)
    end

    # 2. Fallback to Company branding
    if branding.blank? || !branding.values.any?(&:present?)
      company_branding = Setting.get('Company', @company.id, 'branding', {}) rescue {}
      branding = company_branding if company_branding.is_a?(Hash) && company_branding.values.any?(&:present?)
    end

    # 3. Fallback to Platform branding
    if branding.blank? || !branding.values.any?(&:present?)
      platform_branding = Setting.get('Platform', 0, 'branding', {}) rescue {}
      branding = platform_branding if platform_branding.is_a?(Hash)
    end

    branding = {} unless branding.is_a?(Hash)

    # Extract logo (camelCase keys from Settings table)
    logo_url = branding['logo'].presence || branding['portalLogo'].presence ||
               branding[:logo].presence || branding[:portalLogo].presence

    # Extract colors
    accent = (branding['primaryColor'] || branding['primary_color'] ||
              branding[:primaryColor] || branding[:primary_color] || '#2563EB').to_s.delete('#')

    company_name = @company.name

    address = {
      name: company_name,
      phone: @company.phone,
      email: @company.email,
      line1: @company.address_line1,
      city: @company.city,
      state: @company.state,
      zip: @company.zip_code
    }

    # If project has a location, use location address if available
    if @project.location_id.present?
      location = @project.location rescue nil
      if location
        address[:name] = location.name.presence || company_name
        address[:phone] = location.phone.presence || address[:phone]
        address[:line1] = location.try(:address).presence || location.try(:street).presence || address[:line1]
        address[:city] = location.city.presence || address[:city]
        address[:state] = location.state.presence || address[:state]
        address[:zip] = location.try(:zip_code).presence || location.try(:zip).presence || address[:zip]
      end
    end

    { logo_url: logo_url, address: address, accent: accent, company_name: company_name }
  end

  def load_logo(url)
    return nil unless url.present?

    if url.include?('/uploads/')
      relative_path = url.sub(%r{^https?://[^/]+}, '')
      upload_base = ENV['UPLOAD_PATH'] || Rails.root.join('public', 'uploads')
      local_path = File.join(upload_base.to_s.sub(/\/uploads$/, ''), relative_path.sub(/^\//, ''))
      alt_path = File.join(upload_base.to_s, relative_path.sub(%r{^/uploads/}, ''))
      return File.binread(local_path) if File.exist?(local_path)
      return File.binread(alt_path) if File.exist?(alt_path)
    end

    return nil unless url.start_with?('http://', 'https://')
    uri = URI.parse(url)
    redirects = 0
    loop do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = 5
      http.read_timeout = 10
      response = http.request(Net::HTTP::Get.new(uri.request_uri))
      case response
      when Net::HTTPSuccess then return response.body
      when Net::HTTPRedirection
        redirects += 1
        return nil if redirects > 3
        uri = URI.parse(response['location'])
      else return nil
      end
    end
  rescue => e
    Rails.logger.warn "[ProjectPDF] Failed to load logo: #{e.message}"
    nil
  end

  def load_image(url)
    load_logo(url)
  end

  # ── HEADER ──
  def add_header(pdf, brand)
    header_top = pdf.cursor
    accent = brand[:accent]
    addr = brand[:address]

    logo_height = 0
    if brand[:logo_url].present?
      begin
        logo_data = load_logo(brand[:logo_url])
        if logo_data
          pdf.image StringIO.new(logo_data), fit: [150, 60], position: :left
          logo_height = header_top - pdf.cursor
        end
      rescue => e
        Rails.logger.warn "[ProjectPDF] Logo render error: #{e.message}"
      end
    end
    pdf.move_cursor_to header_top if logo_height > 0  # Reset for right-side box
    pdf.text brand[:company_name], size: 18, style: :bold unless logo_height > 0

    # Company info on right side
    right_start = pdf.cursor
    pdf.bounding_box([pdf.bounds.right - 200, header_top], width: 200) do
      pdf.text addr[:name], size: 11, style: :bold, align: :right
      pdf.text addr[:phone], size: 9, align: :right if addr[:phone].present?
      pdf.text addr[:line1], size: 9, align: :right if addr[:line1].present?
      city_state = [addr[:city], addr[:state], addr[:zip]].compact.join(', ')
      pdf.text city_state, size: 9, align: :right if city_state.present?
      pdf.text addr[:email], size: 9, align: :right if addr[:email].present?
    end

    # Move cursor below BOTH logo and company info before drawing rule
    lowest = [pdf.cursor, header_top - [logo_height, 65].max].min
    pdf.move_cursor_to lowest
    pdf.move_down 8
    pdf.stroke_color accent
    pdf.line_width = 1.5
    pdf.stroke_horizontal_rule
    pdf.stroke_color '000000'
    pdf.line_width = 1
  end

  # ── PROJECT OVERVIEW ──
  def add_project_overview(pdf, accent)
    pdf.text 'Project Overview', size: 16, style: :bold, color: accent
    pdf.move_down 10

    p = @project
    meta_top = pdf.cursor
    w = pdf.bounds.width

    # Left column: project details
    left_end = meta_top
    pdf.bounding_box([0, meta_top], width: w * 0.55) do
      label_value(pdf, accent, 'Project', p.name)
      label_value(pdf, accent, 'Project Number', p.project_number) if p.project_number.present?
      label_value(pdf, accent, 'Status', p.status&.titleize)
      label_value(pdf, accent, 'Progress', "#{p.progress_percent}%")
      label_value(pdf, accent, 'Customer', p.customer_name) if p.customer_name.present?
      label_value(pdf, accent, 'Customer Phone', p.customer_phone) if p.customer_phone.present?

      address = [p.delivery_street, p.delivery_city, p.delivery_state, p.delivery_zip].compact.join(', ')
      label_value(pdf, accent, 'Site Address', address) if address.present?
      left_end = pdf.cursor
    end

    # Right column: home info & dates
    right_end = meta_top
    pdf.bounding_box([w * 0.58, meta_top], width: w * 0.42) do
      label_value(pdf, accent, 'Home Make', p.home_make) if p.home_make.present?
      label_value(pdf, accent, 'Home Model', p.home_model) if p.home_model.present?
      label_value(pdf, accent, 'Serial Number', p.home_serial_number) if p.home_serial_number.present?
      label_value(pdf, accent, 'Start Date', format_date(p.started_at)) if p.started_at.present?
      label_value(pdf, accent, 'Est. Completion', format_date(p.estimated_completion_date)) if p.estimated_completion_date.present?
      label_value(pdf, accent, 'Actual Completion', format_date(p.actual_completion_date)) if p.actual_completion_date.present?

      if p.owner.present?
        label_value(pdf, accent, 'Project Manager', p.owner.full_name)
      end
      right_end = pdf.cursor
    end

    # Move below both columns
    pdf.move_cursor_to [left_end, right_end].min
    pdf.move_down 15
  end

  # ── PHASES & TASKS ──
  def add_phases_section(pdf, accent, include_logs: false, include_photos: false)
    phases = @project.project_phases.ordered
      .includes(project_phase_tasks: { contractor_assignments: [:contractor, :work_logs] })

    phases.each_with_index do |phase, idx|
      check_page_break(pdf, 80)

      # Phase header bar with readable white text
      bar_y = pdf.cursor
      bar_height = 24
      pdf.fill_color accent
      pdf.fill_rectangle [0, bar_y], pdf.bounds.width, bar_height
      pdf.fill_color 'FFFFFF'
      pdf.text_box "  #{phase.name}",
        at: [0, bar_y],
        width: pdf.bounds.width,
        height: bar_height,
        valign: :center,
        size: 12,
        style: :bold,
        color: 'FFFFFF',
        overflow: :truncate
      pdf.fill_color '000000'
      pdf.move_cursor_to(bar_y - bar_height)
      pdf.move_down 6

      # Phase meta line
      meta_parts = []
      meta_parts << "Status: #{phase.status_display}"
      if phase.estimated_start_date.present?
        meta_parts << "Start: #{format_date(phase.estimated_start_date)}"
      end
      if phase.estimated_completion_date.present?
        meta_parts << "Due: #{format_date(phase.estimated_completion_date)}"
      end
      summary = phase.tasks_summary
      if summary
        meta_parts << "Tasks: #{summary[:completed]}/#{summary[:total]}"
      end
      pdf.text meta_parts.join('  |  '), size: 9, color: '666666'
      pdf.move_down 8

      # Tasks table
      tasks = phase.project_phase_tasks.sort_by(&:position)
      if tasks.any?
        add_tasks_table(pdf, accent, tasks, include_logs: include_logs, include_photos: include_photos)
      else
        pdf.text '  No tasks defined', size: 9, color: '999999', style: :italic
      end

      pdf.move_down 15
    end
  end

  def add_tasks_table(pdf, accent, tasks, include_logs: false, include_photos: false)
    tasks.each do |task|
      check_page_break(pdf, 40)

      # Task row
      status_icon = task.status == 'completed' ? '[x]' : '[ ]'
      contractor_names = task.contractor_assignments.map { |a| a.contractor&.name }.compact.join(', ')

      pdf.indent(15) do
        pdf.text "#{status_icon}  #{task.name}", size: 10, style: (task.status == 'completed' ? :bold : :normal)

        meta = []
        meta << "Status: #{task.status.titleize}"
        meta << "Assigned: #{contractor_names}" if contractor_names.present?
        if task.estimated_start_date.present?
          meta << "Start: #{format_date(task.estimated_start_date)}"
        end
        if task.estimated_completion_date.present?
          meta << "Due: #{format_date(task.estimated_completion_date)}"
        end
        pdf.text meta.join('  |  '), size: 8, color: '888888' if meta.any?
      end

      # Work logs
      if include_logs
        logs = task.contractor_assignments.flat_map(&:work_logs).sort_by { |l| l.logged_at || l.created_at }.reverse
        if logs.any?
          pdf.move_down 4
          add_work_logs(pdf, accent, logs, include_photos: include_photos)
        end
      end

      pdf.move_down 6
    end
  end

  def add_work_logs(pdf, accent, logs, include_photos: false)
    logs.each do |log|
      check_page_break(pdf, 30)

      pdf.indent(30) do
        timestamp = (log.logged_at || log.created_at)&.strftime('%m/%d/%Y %I:%M %p')
        author = log.author_name || log.contractor&.name || log.user&.full_name || 'Unknown'
        type_label = log.author_type == 'dealer' ? 'Dealer' : 'Contractor'
        badge_color = log.author_type == 'dealer' ? accent : '10B981'

        pdf.text "#{author} (#{type_label}) — #{timestamp}", size: 8, style: :bold, color: badge_color
        pdf.text log.note, size: 9, color: '333333' if log.note.present?

        # Photo thumbnails
        if include_photos && log.attachments.present?
          photo_attachments = Array(log.attachments).select { |a| a.is_a?(Hash) }
          image_attachments = photo_attachments.select { |a| (a['content_type'] || '').start_with?('image/') }
          file_attachments = photo_attachments.reject { |a| (a['content_type'] || '').start_with?('image/') }

          if image_attachments.any?
            pdf.move_down 3
            add_photo_grid(pdf, image_attachments)
          end

          if file_attachments.any?
            pdf.move_down 2
            file_attachments.each do |att|
              pdf.text "[File] #{att['filename'] || 'File'} (#{format_file_size(att['size'])})", size: 8, color: '666666'
            end
          end
        end
      end

      pdf.move_down 4
    end
  end

  def add_photo_grid(pdf, images)
    images.each_slice(3) do |row|
      check_page_break(pdf, 110)
      x = 0
      img_width = (pdf.bounds.width - 60 - 20) / 3  # 30px indent each side + 10px gaps

      row.each do |img|
        url = img['thumbnail_url'] || img['url']
        next unless url.present?

        begin
          img_data = load_image(url)
          if img_data
            pdf.image StringIO.new(img_data), at: [x, pdf.cursor], fit: [img_width, 100]
          end
        rescue => e
          Rails.logger.warn "[ProjectPDF] Image load error: #{e.message}"
          pdf.text "[Image: #{img['filename'] || 'photo'}]", size: 8, color: '999999'
        end
        x += img_width + 10
      end

      pdf.move_down 105
    end
  end

  # ── BUDGET ──
  def add_budget_section(pdf, accent)
    p = @project
    return unless p.budget_amount.present? && p.budget_amount > 0

    check_page_break(pdf, 100)

    pdf.text 'Budget Summary', size: 16, style: :bold, color: accent
    pdf.move_down 10

    budget_data = []
    budget_data << ['Budget', format_currency(p.budget_amount)]
    budget_data << ['Labor', format_currency(p.labor_cost)] if p.labor_cost.to_f > 0
    budget_data << ['Materials', format_currency(p.materials_cost)] if p.materials_cost.to_f > 0
    budget_data << ['Subcontractor', format_currency(p.subcontractor_cost)] if p.subcontractor_cost.to_f > 0
    budget_data << ['Other', format_currency(p.other_cost)] if p.other_cost.to_f > 0
    budget_data << ['Actual Cost', format_currency(p.actual_cost)]

    remaining = (p.budget_amount.to_f - p.actual_cost.to_f)
    budget_data << ['Remaining', format_currency(remaining)]

    pdf.table(budget_data, position: :left, width: 300,
              cell_style: { borders: [], padding: [5, 8], size: 10 }) do |t|
      t.columns(0).font_style = :bold
      t.columns(1).align = :right
      t.row(-1).font_style = :bold
      t.row(-1).borders = [:top]
      t.row(-1).border_width = 1.5
      t.row(-1).border_color = accent
      t.row(-1).text_color = remaining >= 0 ? '10B981' : 'EF4444'
    end

    pdf.move_down 15
  end

  # ── FOOTER ──
  def add_footer(pdf, brand)
    pdf.repeat(:all) do
      pdf.bounding_box([0, -25], width: pdf.bounds.width, height: 30) do
        pdf.stroke_color 'CCCCCC'
        pdf.line_width = 0.5
        pdf.stroke_horizontal_rule
        pdf.move_down 5
        pdf.font_size(7) do
          pdf.text "Generated #{Time.current.strftime('%m/%d/%Y %I:%M %p')}  |  Powered by #{Brand.current.name}",
                   align: :center, color: '999999'
        end
      end
    end
    pdf.number_pages 'Page <page> of <total>',
                     at: [pdf.bounds.right - 100, -45], align: :right, size: 7, color: '999999'
  end

  # ── HELPERS ──
  def label_value(pdf, accent, label, value)
    return if value.blank?
    pdf.text label, size: 8, color: accent
    pdf.text value.to_s, size: 10
    pdf.move_down 5
  end

  def check_page_break(pdf, space_needed)
    pdf.start_new_page if pdf.cursor < space_needed
  end

  def format_date(date)
    return nil unless date
    date.strftime('%m/%d/%Y')
  end

  def format_currency(amount)
    number = amount.to_f
    whole, decimal = sprintf('%.2f', number.abs).split('.')
    whole_with_commas = whole.reverse.scan(/\d{1,3}/).join(',').reverse
    prefix = number < 0 ? '-$' : '$'
    "#{prefix}#{whole_with_commas}.#{decimal}"
  end

  def format_file_size(bytes)
    return 'unknown' unless bytes
    bytes = bytes.to_i
    if bytes < 1024
      "#{bytes} B"
    elsif bytes < 1024 * 1024
      "#{(bytes / 1024.0).round(1)} KB"
    else
      "#{(bytes / (1024.0 * 1024)).round(1)} MB"
    end
  end

  def phase_status_color(status)
    case status
    when 'completed' then '10B981'
    when 'in_progress' then '3B82F6'
    when 'skipped' then '9CA3AF'
    else 'F59E0B'
    end
  end
end
