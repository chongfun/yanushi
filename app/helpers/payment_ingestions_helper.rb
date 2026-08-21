module PaymentIngestionsHelper
  def payment_ingestion_alias_proposal(ingestion)
    party = ingestion.party
    return unless party

    if party.alias_candidate?(ingestion.payer_name)
      ingestion.payer_name
    elsif party.alias_candidate?(ingestion.payer_username)
      ingestion.payer_username
    end
  end
end
