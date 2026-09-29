# frozen_string_literal: true

# Columns that point at confidential files (see PrivateFiles).
#
#   private_file_columns :document_url, :sealed_document_url   # one reference each
#   private_file_lists :document_urls, :completion_photos      # array of references
#   private_file_attachments :attachments, %w[url thumbnail_url]  # array of hashes
#
# On save, every value is normalized to a stored reference, so a presigned URL
# the browser sends back (or a legacy public URL copied from another row) is
# never persisted. `as_json` presigns these columns on the way out, and
# hand-built JSON calls `<column>_link` or `<column>_links`.
module PrivateFileColumns
  extend ActiveSupport::Concern

  included do
    # column name => :column, :list, or the attachment hash fields
    class_attribute :private_file_fields, instance_writer: false, default: {}
  end

  # Any JSON built from the record gets expiring links, never references.
  def serializable_hash(options = nil)
    hash = super
    private_file_fields.each do |col, spec|
      key = col.to_s
      next unless hash.key?(key) && hash[key].present?

      hash[key] =
        case spec
        when :column then PrivateFiles.url(hash[key])
        when :list then Array(hash[key]).map { |v| v.is_a?(String) ? PrivateFiles.url(v) : v }
        else PrivateFiles.presign_attachments(hash[key], *spec)
        end
    end
    hash
  end

  class_methods do
    def private_file_columns(*columns)
      self.private_file_fields = private_file_fields.merge(columns.to_h { |c| [c, :column] })
      columns.each do |col|
        define_method("#{col}_link") do |**opts|
          PrivateFiles.url(self[col], **opts)
        end
      end
      before_save do
        columns.each do |col|
          next unless will_save_change_to_attribute?(col) && self[col].present?

          self[col] = PrivateFiles.normalize(self[col])
        end
      end
    end

    def private_file_lists(*columns)
      self.private_file_fields = private_file_fields.merge(columns.to_h { |c| [c, :list] })
      columns.each do |col|
        define_method("#{col}_links") do |**opts|
          Array(self[col]).map { |v| PrivateFiles.url(v, **opts) }
        end
      end
      before_save do
        columns.each do |col|
          next unless will_save_change_to_attribute?(col) && self[col].is_a?(Array)

          self[col] = self[col].map { |v| v.is_a?(String) ? PrivateFiles.normalize(v) : v }
        end
      end
    end

    def private_file_attachments(column, fields)
      self.private_file_fields = private_file_fields.merge(column => Array(fields))
      define_method("#{column}_links") do |**opts|
        PrivateFiles.presign_attachments(self[column], *fields, **opts)
      end
      before_save do
        if will_save_change_to_attribute?(column) && self[column].is_a?(Array)
          self[column] = PrivateFiles.normalize_attachments(self[column], *fields)
        end
      end
    end
  end
end
