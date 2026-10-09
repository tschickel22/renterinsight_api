# frozen_string_literal: true

# A dealer's agreement package: their contract as a document model the
# platform renders and fills from the deal (Agreements::PacketRenderer), with
# the standard sheets in their place, instead of a fixed PDF.
class AddPacketToAgreementTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :agreement_templates, :packet, :jsonb, null: false, default: {}
  end
end
