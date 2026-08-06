# frozen_string_literal: true

# Which Content Profile a landing page was projected from, and which intake
# form collects its leads.
#
# Provenance matters because projection is cheap and repeatable: knowing the
# source profile means a page can be re-projected into a different layout later
# without re-uploading the document. It also survives cloning, so every copy of
# an offer still points at the spec sheet it came from.
#
# intake_form_id is denormalised out of the contact block's content JSON. The
# block is where the renderer reads it, but a column is what lets a clone decide
# whether to duplicate the form or share it, and what lets a landing page report
# its own submissions without scanning JSONB.
class AddProfileProvenanceToWebsitePages < ActiveRecord::Migration[8.0]
  def change
    add_reference :website_pages, :site_content_profile,
                  null: true, index: true, foreign_key: true
    add_reference :website_pages, :intake_form,
                  null: true, index: true, foreign_key: true

    # Which landing page layout was projected. Kept so "try another design" can
    # show which one is current, and so a re-projection knows what to replace.
    add_column :website_pages, :layout_id, :string
  end
end
