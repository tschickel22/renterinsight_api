# frozen_string_literal: true

# Supplier is now an alias subclass of Vendor (vendor_type='supplier').
# Existing code paths (Parts, Purchase Orders, Recurring Bills) continue to
# use `Supplier` as before; queries are scoped to vendor_type='supplier' via
# default_scope. After the unify-vendors migration, supplier_id columns on
# purchase_orders / recurring_bills / supplier_parts contain vendor IDs.
class Supplier < Vendor
  default_scope { where(vendor_type: 'supplier') }

  before_validation :ensure_vendor_type

  private

  def ensure_vendor_type
    self.vendor_type = 'supplier' if vendor_type.blank?
  end
end
