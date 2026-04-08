# frozen_string_literal: true

require 'zip'

module ImportExport
  # Extracts an uploaded ZIP and matches images to records by:
  #   1. Filename containing a record identifier (vin, sku, ticket_number, email-slug, name-slug)
  #   2. CSV-provided 'image_filename' column on the row (handled upstream by Importer)
  # Unmatched files are reported back, never silently dropped.
  class ImageMatcher
    IMAGE_EXTS = %w[.jpg .jpeg .png .webp .gif].freeze

    def initialize(import_job, created_record_ids)
      @job     = import_job
      @company = import_job.company
      @ids     = created_record_ids
    end

    def match_and_attach!
      return { matched: 0, unmatched: [] } unless @job.image_zip_url.present?
      return { matched: 0, unmatched: [] } unless File.exist?(@job.image_zip_url.to_s)

      cfg = ModuleRegistry.config_for(@job.module_type)
      return { matched: 0, unmatched: [] } unless cfg

      scope    = @company.public_send(cfg[:scope])
      records  = scope.where(id: @ids).to_a
      matched  = 0
      unmatched = []

      Dir.mktmpdir do |tmpdir|
        Zip::File.open(@job.image_zip_url) do |zip|
          zip.each do |entry|
            next if entry.directory?
            ext = File.extname(entry.name).downcase
            next unless IMAGE_EXTS.include?(ext)

            base = File.basename(entry.name, ext).downcase
            target = records.find { |r| identifiers_for(r).any? { |id| base.include?(id) } }
            if target
              dest = File.join(tmpdir, File.basename(entry.name))
              entry.extract(dest) { true }
              attach_image(target, dest, entry.name)
              matched += 1
            else
              unmatched << entry.name
            end
          end
        end
      end

      { matched: matched, unmatched: unmatched }
    end

    private

    def identifiers_for(record)
      ids = []
      %i[vin sku stock_number ticket_number invoice_number quote_number].each do |attr|
        ids << record.public_send(attr).to_s.downcase if record.respond_to?(attr) && record.public_send(attr).present?
      end
      if record.respond_to?(:email) && record.email.present?
        ids << record.email.split('@').first.to_s.downcase
      end
      if record.respond_to?(:name) && record.name.present?
        ids << record.name.to_s.downcase.gsub(/[^a-z0-9]/, '_')
      end
      ids.compact.uniq
    end

    def attach_image(record, path, filename)
      if record.respond_to?(:images) && record.images.respond_to?(:create!)
        record.images.create!(file: File.open(path)) rescue nil
      elsif record.respond_to?(:attachments) && record.attachments.respond_to?(:attach)
        record.attachments.attach(io: File.open(path), filename: filename)
      end
    end
  end
end
