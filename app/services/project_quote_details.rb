# frozen_string_literal: true

# "Share quote details with installers": a scope sheet of the deal's quote,
# filed on the project for the installer to work from. It lists every line
# (description, category, quantity, notes) and never a price, a cost or a
# total. The installer sees it; the buyer does not. It is on when the project
# has the sheet, so turning it off removes it. When the quote's items change,
# the sheet is made again from them.
class ProjectQuoteDetails
  FLAG = 'quote_details'

  # Never shown: money of any kind, and anything internal.
  HIDDEN_KEY = /price|cost|total|amount|rate|discount|tax|margin|profit|markup|gross|internal/i

  class Error < StandardError; end

  # The deal's quote the sheet is made from: the accepted one, else the latest.
  def self.quote_for(project)
    return nil unless project.deal_id

    quotes = Quote.where(company_id: project.company_id, deal_id: project.deal_id, is_deleted: [false, nil])
    quotes.where(status: 'accepted').order(accepted_at: :desc, id: :desc).first ||
      quotes.where.not(status: %w[rejected expired]).order(updated_at: :desc, id: :desc).first
  end

  # Remakes the sheet on every project of this quote's deal that has it on.
  def self.quote_changed(quote)
    return unless quote.deal_id

    Project.where(company_id: quote.company_id, deal_id: quote.deal_id).find_each do |project|
      service = new(project)
      doc = service.document
      next unless doc

      # Remake it when it is made from this quote, or this quote is now the one it should use.
      service.refresh! if doc.metadata&.dig('quote_id') == quote.id || service.quote&.id == quote.id
    end
  end

  def initialize(project, user: nil)
    @project = project
    @user = user
  end

  def quote
    @quote ||= self.class.quote_for(@project)
  end

  def document
    @project.project_documents.not_deleted.where("metadata ->> '#{FLAG}' = 'true'").order(:id).last
  end

  def status
    doc = document
    {
      enabled: doc.present?,
      quote: quote && { id: quote.id, quote_number: quote.quote_number, status: quote.status },
      document: doc && { id: doc.id, title: doc.title, file_name: doc.file_name, created_at: doc.created_at,
                         quote_id: doc.metadata&.dig('quote_id') },
      lines: quote ? lines(quote).size : 0
    }
  end

  def enable!
    raise Error, "This project's deal has no quote to share" unless quote

    remove!(document) if document
    body = ProjectQuoteDetailsPdf.new(@project, quote, lines(quote)).render
    key = "projects/#{@project.company_id}/#{@project.id}/documents/quote-details-#{quote.quote_number.to_s.parameterize}-#{SecureRandom.hex(4)}.pdf"
    ref = PrivateFiles.put(body, key: key, content_type: 'application/pdf')
    doc = @project.project_documents.create!(
      company_id: @project.company_id, uploaded_by_id: @user&.id, source: 'dealer',
      title: "Quote details (#{quote.quote_number})", category: 'other',
      description: 'Each item on the quote, without prices, for the installer.',
      file_url: ref, file_s3_key: key, file_name: "Quote details #{quote.quote_number}.pdf",
      file_size: body.bytesize, content_type: 'application/pdf',
      client_visible: false, contractor_visible: true,
      # link_shared: a linked installer company gets its own copy too (E68).
      metadata: { FLAG => true, 'quote_id' => quote.id, 'link_shared' => true }
    )
    ProjectLinkDocumentJob.perform_later(doc.id)
    doc
  end

  def disable!
    doc = document
    remove!(doc) if doc
    nil
  end

  def refresh!
    enable!
  end

  # What goes on the sheet: each line with money taken out. Credit and
  # discount lines are left out (they are money, not work).
  def lines(q)
    Array(q.items).filter_map do |item|
      next unless item.is_a?(Hash)

      total = (item['total'] || item['lineTotal']).to_f
      next if total.negative?

      description = item['description'].presence || item['name'].presence
      next if description.blank?

      { description: description.to_s, category: item['category'].to_s.tr('_', ' ').presence,
        quantity: item['quantity'].presence || 1, notes: item['notes'].to_s.strip.presence }
    end
  end

  private

  # Removes the sheet: the stored file, and a linked installer's copy (the
  # link job removes copies of a deleted original).
  def remove!(doc)
    doc.update!(is_deleted: true)
    PrivateFiles.delete(doc.file_url.presence || doc.file_s3_key)
    ProjectLinkDocumentJob.perform_later(doc.id)
  end
end
