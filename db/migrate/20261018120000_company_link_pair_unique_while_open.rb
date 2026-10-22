# frozen_string_literal: true

# Two companies could never link again once a link between them ended: the
# pair was unique across every link, ended ones included. Only one open link
# per pair now; ended links stay as history.
class CompanyLinkPairUniqueWhileOpen < ActiveRecord::Migration[8.0]
  def change
    remove_index :company_links, name: 'index_company_links_on_pair',
                                 column: %i[dealer_company_id installer_company_id], unique: true,
                                 where: 'installer_company_id IS NOT NULL'
    add_index :company_links, %i[dealer_company_id installer_company_id], unique: true,
              where: "installer_company_id IS NOT NULL AND status <> 'ended'", name: 'index_company_links_on_open_pair'
  end
end
