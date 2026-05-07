# frozen_string_literal: true

# Contractor is now an alias subclass of Vendor (vendor_type='contractor').
# Existing code paths (Contractor Portal, contractor assignments, project
# costs) continue to use `Contractor` as before; queries are scoped to
# vendor_type='contractor' via default_scope.
class Contractor < Vendor
  default_scope { where(vendor_type: 'contractor') }

  before_validation :ensure_vendor_type

  private

  def ensure_vendor_type
    self.vendor_type = 'contractor' if vendor_type.blank?
  end
end
