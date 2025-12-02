# frozen_string_literal: true

# app/services/loan_document_service.rb
#
# Service to handle document management for loans
# Documents are owned by Contact (the person) and may be related to Loan (the financing)

class LoanDocumentService
  attr_reader :loan, :user
  
  def initialize(loan, user = nil)
    @loan = loan
    @user = user
  end
  
  # Upload a document for a loan
  def upload_document(file:, category: 'loan_agreement', name: nil, description: nil)
    raise ArgumentError, 'File is required' unless file.present?
    
    # Get the borrower (should be a Contact)
    borrower = loan.borrower
    
    unless borrower.is_a?(::Contact)
      Rails.logger.warn "[LoanDocumentService] Loan #{loan.id} borrower is not a Contact (type: #{loan.borrower_type})"
      return create_loan_owned_document(file, category, name, description)
    end
    
    # Create document owned by Contact, related to Loan
    document = PortalDocument.new(
      owner: borrower,
      related_to: loan,
      document_name: name || file.original_filename,
      category: category,
      description: description,
      uploaded_by: user&.id&.to_s || 'admin',
      uploaded_at: Time.current
    )
    
    document.file.attach(file)
    
    if document.save
      Rails.logger.info "[LoanDocumentService] Document #{document.id} created for loan #{loan.id}, owned by Contact #{borrower.id}"
      document
    else
      Rails.logger.error "[LoanDocumentService] Failed to create document: #{document.errors.full_messages.join(', ')}"
      raise ActiveRecord::RecordInvalid, document
    end
  end
  
  # Get all documents for a loan
  # Returns ALL documents owned by the borrower (Contact)
  def all_documents
    borrower = loan.borrower
    
    return PortalDocument.none unless borrower.is_a?(::Contact)
    
    # Return ALL documents owned by this contact
    # They all belong to the contact, and the contact belongs to the loan
    PortalDocument.where(owner_type: 'Contact', owner_id: borrower.id)
                  .order(created_at: :desc)
  end
  
  # Delete a document
  def delete_document(document_id)
    document = all_documents.find_by(id: document_id)
    raise ActiveRecord::RecordNotFound, "Document #{document_id} not found" unless document
    document.destroy
  end
  
  private
  
  def create_loan_owned_document(file, category, name, description)
    # Fallback for loans without Contact borrower
    document = PortalDocument.new(
      owner: loan,
      document_name: name || file.original_filename,
      category: category,
      description: description,
      uploaded_by: user&.id&.to_s || 'admin',
      uploaded_at: Time.current
    )
    document.file.attach(file)
    if document.save
      Rails.logger.info "[LoanDocumentService] Fallback: Document #{document.id} created owned by loan #{loan.id}"
      document
    else
      raise ActiveRecord::RecordInvalid, document
    end
  end
end
