# E68 step 2: a contractor's invoice uploaded in the portal becomes a draft bill
# linked to the project and to the project cost line it pays for.
class LinkContractorInvoicesToBills < ActiveRecord::Migration[8.0]
  def change
    add_reference :project_cost_items, :bill, foreign_key: { on_delete: :nullify }
    add_reference :bills, :project, foreign_key: { on_delete: :nullify }
    # Where the bill came from, e.g. 'contractor_portal'. Blank for bills
    # entered by the dealer.
    add_column :bills, :source, :string
    # The contractor's portal submission: the assignment it was sent from and
    # what they typed, kept apart from what the dealer edits on the bill.
    add_column :bills, :submission, :jsonb, default: {}, null: false
  end
end
