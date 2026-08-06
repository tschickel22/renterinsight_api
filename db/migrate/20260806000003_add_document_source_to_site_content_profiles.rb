# frozen_string_literal: true

# Lets a Client Content Profile come from an uploaded document, not just a crawl.
#
# The profile is the durable artifact the importer is built around, and it is
# deliberately template-agnostic — so a scanned dealer website and an uploaded
# product sheet can be the same kind of input to the same builder, and both
# project into every layout. Adding a second source beats bolting a parallel
# model onto the side of it.
class AddDocumentSourceToSiteContentProfiles < ActiveRecord::Migration[8.0]
  def change
    # 'url' | 'manual' | 'document'. Existing rows are crawls or hand-entered
    # demos; `entered_manually?` already distinguishes those two by inspecting
    # the profile payload, so backfilling everything to 'url' would be wrong.
    # Left to the model to resolve for old rows.
    add_column :site_content_profiles, :source_kind, :string, default: 'url', null: false
    add_index :site_content_profiles, :source_kind

    # What was uploaded. Kept so a profile can be re-extracted later — against a
    # newer schema or a better prompt — without asking for the file again.
    add_column :site_content_profiles, :document_filename, :string
    add_column :site_content_profiles, :document_s3_key, :string
    add_column :site_content_profiles, :document_content_type, :string
    add_column :site_content_profiles, :document_byte_size, :bigint

    # How many pages were rendered to images for the vision pass. Zero means the
    # scan read text only — worth surfacing, because it is the difference
    # between a profile that matched the document's design and one that guessed.
    add_column :site_content_profiles, :rasterized_page_count, :integer
  end
end
