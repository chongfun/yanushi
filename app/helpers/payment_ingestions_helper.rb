module PaymentIngestionsHelper
  def payment_ingestion_alias_proposal(ingestion)
    tenant = ingestion.tenant
    return unless tenant

    if tenant.alias_candidate?(ingestion.payer_name)
      ingestion.payer_name
    elsif tenant.alias_candidate?(ingestion.payer_username)
      ingestion.payer_username
    end
  end
end
