# Run from Rails console to re-seal the most recent completed agreement:
#   load 'lib/tasks/reseal.rb'
#
# Or re-seal a specific agreement:
#   load 'lib/tasks/reseal.rb'; reseal(42)

def reseal(agreement_id = nil)
  agreement = if agreement_id
    Agreement.find(agreement_id)
  else
    Agreement.where(status: 'completed').order(completed_at: :desc).first
  end

  unless agreement
    puts "❌ No completed agreement found"
    return
  end

  puts "Re-sealing: #{agreement.agreement_number} (ID: #{agreement.id})"
  puts "  Title: #{agreement.title}"
  puts "  Current sealed_document_url: #{agreement.sealed_document_url.present? ? 'SET' : 'nil'}"

  # Clear sealed URL so we regenerate it
  agreement.update_column(:sealed_document_url, nil)

  service = AgreementPdfService.new(agreement)
  result = service.seal_document

  agreement.reload
  puts "\n✅ Done!"
  puts "  sealed_document_url: #{agreement.sealed_document_url.present? ? agreement.sealed_document_url[0..80] : 'nil'}"
  puts "  Different from source? #{agreement.sealed_document_url != (agreement.document_url.presence || agreement.document_urls&.first)}"
end

# Auto-run on the most recent
reseal
