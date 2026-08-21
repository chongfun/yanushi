module ImportedTransactionsHelper
  def imported_transaction_alias_proposal(transaction)
    party = transaction.matched_party
    return unless party

    if party.alias_candidate?(transaction.payer_name)
      transaction.payer_name
    elsif party.alias_candidate?(transaction.payer_username)
      transaction.payer_username
    end
  end
end
