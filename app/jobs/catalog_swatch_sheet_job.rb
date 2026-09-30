# frozen_string_literal: true

# Reads an uploaded decor sheet into swatches (Catalog::Swatches::SheetReader).
class CatalogSwatchSheetJob < ApplicationJob
  queue_as :default

  def perform(sheet_id)
    sheet = CatalogSwatchSheet.find_by(id: sheet_id)
    return unless sheet

    sheet.update!(status: 'reading', error: nil)
    result = Catalog::Swatches::SheetReader.new(PrivateFiles.read(sheet.storage_ref), filename: sheet.filename).call
    s3 = S3UploadService.new
    saved = result[:swatches].map do |s|
      swatch = CatalogSwatch.where(manufacturer_id: sheet.manufacturer_id, factory_id: sheet.factory_id)
                            .where('lower(set_name) = ? AND lower(name) = ?', s[:set].downcase, s[:name].downcase)
                            .first_or_initialize(set_name: s[:set], name: s[:name])
      bytes = s[:image].thumbnail_image(900, height: 900, size: :down).jpegsave_buffer(Q: 88)
      key = "truebuild/swatches/#{sheet.manufacturer_id}/#{Digest::SHA256.hexdigest(bytes)[0, 20]}.jpg"
      s3.s3_client.put_object(bucket: s3.bucket_name, key: key, body: bytes, content_type: 'image/jpeg')
      swatch.update!(catalog_swatch_sheet: sheet, note: s[:note], hex: s[:hex], page: s[:page],
                     image_url: "https://#{s3.bucket_name}.s3.#{s3.region}.amazonaws.com/#{key}")
      swatch
    end
    sheet.update!(status: 'done', swatch_count: saved.size, missed: result[:missed].map(&:stringify_keys), cost_usd: result[:cost_usd])
  rescue Catalog::Swatches::SheetReader::Error, Catalog::PriceBooks::ClaudeClient::Error, PrivateFiles::Forbidden => e
    sheet&.update!(status: 'failed', error: e.message.first(500))
  rescue StandardError => e
    Rails.logger.error("[Swatches] sheet #{sheet_id}: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    sheet&.update!(status: 'failed', error: "Unexpected error: #{e.message.first(300)}")
  end
end
