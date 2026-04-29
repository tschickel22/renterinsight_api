# frozen_string_literal: true

# Hardcoded field metadata for workflow automation UI.
# Drives the branch condition builder, update_field dropdowns,
# and merge tag picker on the frontend.
#
# To add a new entity type:
#   1. Add it to SUPPORTED_TYPES
#   2. Add a FIELDS_<TYPE> constant
#   3. Add a MERGE_TAGS_<TYPE> constant
#   4. Add the case branch in self.for
#
# This is intentionally hardcoded — not introspected from the schema —
# so we have explicit control over what dealers can see/update.
#
# Allowed field type values:
#   string, textarea, number, boolean, select, date, datetime, user

module WorkflowFieldMetadata
  SUPPORTED_TYPES = %w[Lead Deal Contact Account ServiceTicket Vehicle Listing].freeze

  # ---------- Common merge tags available for all entities ----------
  GLOBAL_MERGE_TAGS = [
    { key: "company.name",         label: "Your Company Name",  entity_type: nil },
    { key: "company.phone",        label: "Your Company Phone", entity_type: nil },
    { key: "company.email",        label: "Your Company Email", entity_type: nil },
    { key: "current_user.name",    label: "Current User Name",  entity_type: nil },
    { key: "current_user.email",   label: "Current User Email", entity_type: nil },
    { key: "current_date",         label: "Today's Date",       entity_type: nil }
  ].freeze

  # ---------- Lead ----------
  FIELDS_LEAD = [
    { key: "first_name",   label: "First Name",   type: "string",   updatable: true,  filterable: true },
    { key: "last_name",    label: "Last Name",    type: "string",   updatable: true,  filterable: true },
    { key: "email",        label: "Email",        type: "string",   updatable: true,  filterable: true },
    { key: "phone",        label: "Phone",        type: "string",   updatable: true,  filterable: true },
    { key: "status",       label: "Status",       type: "select",   updatable: true,  filterable: true,
      options: %w[new contacted qualified proposal won lost] },
    { key: "source",       label: "Source",       type: "string",   updatable: true,  filterable: true },
    { key: "owner_id",     label: "Owner",        type: "user",     updatable: true,  filterable: true },
    { key: "notes",        label: "Notes",        type: "textarea", updatable: true,  filterable: false },
    { key: "created_at",   label: "Created At",   type: "datetime", updatable: false, filterable: true },
    { key: "updated_at",   label: "Updated At",   type: "datetime", updatable: false, filterable: true }
  ].freeze

  MERGE_TAGS_LEAD = [
    { key: "entity.first_name",  label: "First Name",  entity_type: "Lead" },
    { key: "entity.last_name",   label: "Last Name",   entity_type: "Lead" },
    { key: "entity.full_name",   label: "Full Name",   entity_type: "Lead" },
    { key: "entity.email",       label: "Email",       entity_type: "Lead" },
    { key: "entity.phone",       label: "Phone",       entity_type: "Lead" },
    { key: "entity.source",      label: "Source",      entity_type: "Lead" },
    { key: "entity.status",      label: "Status",      entity_type: "Lead" },
    { key: "entity.owner_email", label: "Owner Email", entity_type: "Lead" },
    { key: "entity.owner_phone", label: "Owner Phone", entity_type: "Lead" },
    { key: "entity.owner_name",  label: "Owner Name",  entity_type: "Lead" }
  ].freeze

  # ---------- Deal ----------
  FIELDS_DEAL = [
    { key: "name",                label: "Deal Name",           type: "string",   updatable: true,  filterable: true },
    { key: "stage",               label: "Stage",               type: "select",   updatable: true,  filterable: true,
      options: %w[prospect qualified proposal negotiation won lost] },
    { key: "amount",              label: "Amount",              type: "number",   updatable: true,  filterable: true },
    { key: "probability",         label: "Probability (%)",     type: "number",   updatable: true,  filterable: true },
    { key: "expected_close_date", label: "Expected Close Date", type: "date",     updatable: true,  filterable: true },
    { key: "owner_id",            label: "Owner",               type: "user",     updatable: true,  filterable: true },
    { key: "account_id",          label: "Account ID",          type: "number",   updatable: false, filterable: true },
    { key: "notes",               label: "Notes",               type: "textarea", updatable: true,  filterable: false },
    { key: "created_at",          label: "Created At",          type: "datetime", updatable: false, filterable: true },
    { key: "updated_at",          label: "Updated At",          type: "datetime", updatable: false, filterable: true }
  ].freeze

  MERGE_TAGS_DEAL = [
    { key: "entity.name",                label: "Deal Name",           entity_type: "Deal" },
    { key: "entity.stage",               label: "Stage",               entity_type: "Deal" },
    { key: "entity.amount",              label: "Amount",              entity_type: "Deal" },
    { key: "entity.probability",         label: "Probability",         entity_type: "Deal" },
    { key: "entity.expected_close_date", label: "Expected Close Date", entity_type: "Deal" },
    { key: "entity.owner_email",         label: "Owner Email",         entity_type: "Deal" },
    { key: "entity.owner_phone",         label: "Owner Phone",         entity_type: "Deal" },
    { key: "entity.owner_name",          label: "Owner Name",          entity_type: "Deal" },
    { key: "entity.account_name",        label: "Account Name",        entity_type: "Deal" }
  ].freeze

  # ---------- Contact ----------
  FIELDS_CONTACT = [
    { key: "first_name",  label: "First Name", type: "string",   updatable: true,  filterable: true },
    { key: "last_name",   label: "Last Name",  type: "string",   updatable: true,  filterable: true },
    { key: "email",       label: "Email",      type: "string",   updatable: true,  filterable: true },
    { key: "phone",       label: "Phone",      type: "string",   updatable: true,  filterable: true },
    { key: "title",       label: "Job Title",  type: "string",   updatable: true,  filterable: true },
    { key: "account_id",  label: "Account ID", type: "number",   updatable: true,  filterable: true },
    { key: "owner_id",    label: "Owner",      type: "user",     updatable: true,  filterable: true },
    { key: "notes",       label: "Notes",      type: "textarea", updatable: true,  filterable: false },
    { key: "created_at",  label: "Created At", type: "datetime", updatable: false, filterable: true },
    { key: "updated_at",  label: "Updated At", type: "datetime", updatable: false, filterable: true }
  ].freeze

  MERGE_TAGS_CONTACT = [
    { key: "entity.first_name",   label: "First Name",   entity_type: "Contact" },
    { key: "entity.last_name",    label: "Last Name",    entity_type: "Contact" },
    { key: "entity.full_name",    label: "Full Name",    entity_type: "Contact" },
    { key: "entity.email",        label: "Email",        entity_type: "Contact" },
    { key: "entity.phone",        label: "Phone",        entity_type: "Contact" },
    { key: "entity.title",        label: "Job Title",    entity_type: "Contact" },
    { key: "entity.owner_email",  label: "Owner Email",  entity_type: "Contact" },
    { key: "entity.owner_name",   label: "Owner Name",   entity_type: "Contact" },
    { key: "entity.account_name", label: "Account Name", entity_type: "Contact" }
  ].freeze

  # ---------- Account ----------
  FIELDS_ACCOUNT = [
    { key: "name",          label: "Name",         type: "string",   updatable: true,  filterable: true },
    { key: "account_type",  label: "Type",         type: "select",   updatable: true,  filterable: true,
      options: %w[customer prospect partner vendor] },
    { key: "email",         label: "Email",        type: "string",   updatable: true,  filterable: true },
    { key: "phone",         label: "Phone",        type: "string",   updatable: true,  filterable: true },
    { key: "website",       label: "Website",      type: "string",   updatable: true,  filterable: true },
    { key: "industry",      label: "Industry",     type: "string",   updatable: true,  filterable: true },
    { key: "owner_id",      label: "Owner",        type: "user",     updatable: true,  filterable: true },
    { key: "notes",         label: "Notes",        type: "textarea", updatable: true,  filterable: false },
    { key: "created_at",    label: "Created At",   type: "datetime", updatable: false, filterable: true },
    { key: "updated_at",    label: "Updated At",   type: "datetime", updatable: false, filterable: true }
  ].freeze

  MERGE_TAGS_ACCOUNT = [
    { key: "entity.name",        label: "Account Name", entity_type: "Account" },
    { key: "entity.email",       label: "Email",        entity_type: "Account" },
    { key: "entity.phone",       label: "Phone",        entity_type: "Account" },
    { key: "entity.website",     label: "Website",      entity_type: "Account" },
    { key: "entity.industry",    label: "Industry",     entity_type: "Account" },
    { key: "entity.owner_email", label: "Owner Email",  entity_type: "Account" },
    { key: "entity.owner_name",  label: "Owner Name",   entity_type: "Account" }
  ].freeze

  # ---------- ServiceTicket ----------
  FIELDS_SERVICE_TICKET = [
    { key: "ticket_number",       label: "Ticket Number", type: "string",   updatable: false, filterable: true },
    { key: "title",               label: "Title",         type: "string",   updatable: true,  filterable: true },
    { key: "status",              label: "Status",        type: "select",   updatable: true,  filterable: true,
      options: %w[open in_progress waiting_on_customer resolved closed] },
    { key: "priority",            label: "Priority",      type: "select",   updatable: true,  filterable: true,
      options: %w[low medium high urgent] },
    { key: "assigned_to_user_id", label: "Assigned To",   type: "user",     updatable: true,  filterable: true },
    { key: "description",         label: "Description",   type: "textarea", updatable: true,  filterable: false },
    { key: "created_at",          label: "Created At",    type: "datetime", updatable: false, filterable: true },
    { key: "updated_at",          label: "Updated At",    type: "datetime", updatable: false, filterable: true }
  ].freeze

  MERGE_TAGS_SERVICE_TICKET = [
    { key: "entity.ticket_number",      label: "Ticket Number",      entity_type: "ServiceTicket" },
    { key: "entity.title",              label: "Title",              entity_type: "ServiceTicket" },
    { key: "entity.status",             label: "Status",             entity_type: "ServiceTicket" },
    { key: "entity.priority",           label: "Priority",           entity_type: "ServiceTicket" },
    { key: "entity.contact_email",      label: "Contact Email",      entity_type: "ServiceTicket" },
    { key: "entity.contact_first_name", label: "Contact First Name", entity_type: "ServiceTicket" },
    { key: "entity.contact_last_name",  label: "Contact Last Name",  entity_type: "ServiceTicket" },
    { key: "entity.assigned_to_name",   label: "Assigned To Name",   entity_type: "ServiceTicket" }
  ].freeze

  # ---------- Vehicle ----------
  FIELDS_VEHICLE = [
    { key: "year",          label: "Year",          type: "number",   updatable: false, filterable: true },
    { key: "make",          label: "Make",          type: "string",   updatable: false, filterable: true },
    { key: "model",         label: "Model",         type: "string",   updatable: false, filterable: true },
    { key: "serial_number", label: "Serial Number", type: "string",   updatable: false, filterable: true },
    { key: "stock_number",  label: "Stock Number",  type: "string",   updatable: false, filterable: true },
    { key: "sale_price",    label: "Sale Price",    type: "number",   updatable: true,  filterable: true },
    { key: "rent_price",    label: "Rent Price",    type: "number",   updatable: true,  filterable: true },
    { key: "status",        label: "Status",        type: "string",   updatable: true,  filterable: true },
    { key: "description",   label: "Description",   type: "textarea", updatable: true,  filterable: false },
    { key: "location",      label: "Location",      type: "string",   updatable: true,  filterable: true },
    { key: "created_at",    label: "Created At",    type: "datetime", updatable: false, filterable: true },
    { key: "updated_at",    label: "Updated At",    type: "datetime", updatable: false, filterable: true }
  ].freeze

  MERGE_TAGS_VEHICLE = [
    { key: "vehicle.year",          label: "Year",          entity_type: "Vehicle" },
    { key: "vehicle.make",          label: "Make",          entity_type: "Vehicle" },
    { key: "vehicle.model",         label: "Model",         entity_type: "Vehicle" },
    { key: "vehicle.serial_number", label: "Serial Number", entity_type: "Vehicle" },
    { key: "vehicle.stock_number",  label: "Stock Number",  entity_type: "Vehicle" },
    { key: "vehicle.sale_price",    label: "Sale Price",    entity_type: "Vehicle" },
    { key: "vehicle.rent_price",    label: "Rent Price",    entity_type: "Vehicle" },
    { key: "vehicle.status",        label: "Status",        entity_type: "Vehicle" },
    { key: "vehicle.location",      label: "Location",      entity_type: "Vehicle" },
    { key: "vehicle.description",   label: "Description",   entity_type: "Vehicle" }
  ].freeze

  # ---------- Listing ----------
  FIELDS_LISTING = [
    { key: "property_name", label: "Property Name", type: "string",   updatable: true,  filterable: true },
    { key: "sale_price",    label: "Sale Price",    type: "number",   updatable: true,  filterable: true },
    { key: "rent_price",    label: "Rent Price",    type: "number",   updatable: true,  filterable: true },
    { key: "status",        label: "Status",        type: "string",   updatable: true,  filterable: true },
    { key: "description",   label: "Description",   type: "textarea", updatable: true,  filterable: false },
    { key: "created_at",    label: "Created At",    type: "datetime", updatable: false, filterable: true },
    { key: "updated_at",    label: "Updated At",    type: "datetime", updatable: false, filterable: true }
  ].freeze

  MERGE_TAGS_LISTING = [
    { key: "listing.property_name", label: "Property Name", entity_type: "Listing" },
    { key: "listing.sale_price",    label: "Sale Price",    entity_type: "Listing" },
    { key: "listing.rent_price",    label: "Rent Price",    entity_type: "Listing" },
    { key: "listing.status",        label: "Status",        entity_type: "Listing" },
    { key: "listing.url",           label: "URL",           entity_type: "Listing" },
    { key: "listing.address",       label: "Address",       entity_type: "Listing" },
    { key: "listing.description",   label: "Description",   entity_type: "Listing" }
  ].freeze

  def self.for(entity_type)
    fields, merge_tags = case entity_type
    when "Lead"          then [FIELDS_LEAD, MERGE_TAGS_LEAD]
    when "Deal"          then [FIELDS_DEAL, MERGE_TAGS_DEAL]
    when "Contact"       then [FIELDS_CONTACT, MERGE_TAGS_CONTACT]
    when "Account"       then [FIELDS_ACCOUNT, MERGE_TAGS_ACCOUNT]
    when "ServiceTicket" then [FIELDS_SERVICE_TICKET, MERGE_TAGS_SERVICE_TICKET]
    when "Vehicle"       then [FIELDS_VEHICLE, MERGE_TAGS_VEHICLE]
    when "Listing"       then [FIELDS_LISTING, MERGE_TAGS_LISTING]
    else
      raise ArgumentError, "Unknown entity_type: #{entity_type}"
    end

    {
      entity_type: entity_type,
      fields: fields,
      merge_tags: merge_tags + GLOBAL_MERGE_TAGS
    }
  end

  def self.all
    SUPPORTED_TYPES.each_with_object({}) do |type, acc|
      data = self.for(type)
      acc[type] = { fields: data[:fields], merge_tags: data[:merge_tags] }
    end
  end
end
