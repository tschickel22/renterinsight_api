# frozen_string_literal: true

# Agreements copied a template's type (upload, editor) into content_type,
# which the agreement builder reads as pdf_upload or rich_text: a PDF
# agreement stored as upload opened in the text editor. Agreement now
# normalizes on save; this repairs the rows already written, including PDF
# agreements the builder's editor autosaved as rich_text with no text.
class NormalizeAgreementContentTypes < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE agreements SET content_type = CASE
        WHEN COALESCE(content, '') = ''
             AND (COALESCE(document_url, '') <> ''
                  OR (jsonb_typeof(document_urls) = 'array' AND jsonb_array_length(document_urls) > 0)) THEN 'pdf_upload'
        WHEN content_type IN ('editor', 'html', 'rich_text') THEN 'rich_text'
        WHEN COALESCE(document_url, '') <> '' THEN 'pdf_upload'
        WHEN COALESCE(content, '') <> '' THEN 'rich_text'
        WHEN EXISTS (SELECT 1 FROM agreement_templates t WHERE t.id = agreements.agreement_template_id AND t.template_type = 'editor') THEN 'rich_text'
        ELSE 'pdf_upload'
      END
      WHERE content_type IS DISTINCT FROM 'pdf_upload'
    SQL
  end

  def down; end
end
